import SwiftUI
import Photos
import AVFoundation
import ImageIO

/// The photos and videos taken with Ring Light. They live in the camera roll;
/// the app just remembers which ones are its own (by Photos ID), newest first.
final class CaptureLibrary: ObservableObject {
    static let shared = CaptureLibrary()

    @Published private(set) var assets: [PHAsset] = []
    /// Shown on the gallery button.
    @Published private(set) var latestThumbnail: UIImage?
    @Published private(set) var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private let idsKey = "capturedAssetIDs"
    private var ids: [String] {
        get { UserDefaults.standard.stringArray(forKey: idsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: idsKey) }
    }

    private init() {
        reload()
    }

    var canBrowse: Bool { access == .authorized || access == .limited }

    /// Called after something is saved to the camera roll.
    func add(id: String, thumbnail: UIImage?) {
        DispatchQueue.main.async {
            self.ids.insert(id, at: 0)
            if let thumbnail { self.latestThumbnail = thumbnail }
            self.reload()
        }
    }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                self.access = status
                self.reload()
            }
        }
    }

    /// Re-reads the app's shots from Photos (drops any deleted elsewhere).
    func reload() {
        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canBrowse else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var found: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in found[asset.localIdentifier] = asset }
        assets = ids.compactMap { found[$0] }
        if let newest = assets.first {
            Task {
                let image = await Self.image(for: newest, size: CGSize(width: 160, height: 160))
                await MainActor.run { self.latestThumbnail = image ?? self.latestThumbnail }
            }
        } else {
            latestThumbnail = nil
        }
    }

    /// Deletes from the camera roll (iOS asks the user to confirm).
    func delete(_ asset: PHAsset, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }) { deleted, _ in
            DispatchQueue.main.async {
                if deleted { self.ids.removeAll { $0 == asset.localIdentifier } }
                self.reload()
                completion(deleted)
            }
        }
    }

    // MARK: - Loading images

    static func image(for asset: PHAsset, size: CGSize, mode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat  // exactly one callback
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: mode, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func thumbnail(photoData data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 200,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func thumbnail(videoAt url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        guard let (cg, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: cg)
    }
}
