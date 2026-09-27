import SwiftUI
import Photos
import AVKit
import ImageIO

/// Everything taken with Ring Light: a grid, and a full-screen viewer to swipe
/// through, play, edit and delete.
struct GalleryView: View {
    @ObservedObject var library: CaptureLibrary
    var onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if !library.canBrowse {
                    accessNeeded
                } else if library.assets.isEmpty {
                    ContentUnavailableView("No shots yet", systemImage: "camera",
                                           description: Text("Photos and videos you take with Ring Light show up here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(library.assets, id: \.localIdentifier) { asset in
                                NavigationLink(value: asset.localIdentifier) {
                                    GridCell(asset: asset)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ring Light")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                AssetViewer(library: library, currentID: id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .onAppear {
            if library.access == .notDetermined {
                library.requestAccess()
            } else {
                library.reload()
            }
        }
    }

    private var accessNeeded: some View {
        ContentUnavailableView {
            Label("Allow Photos access", systemImage: "photo.on.rectangle")
        } description: {
            Text("Ring Light needs access to your photos to show, edit and delete the shots you took with it.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct GridCell: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(Duration.seconds(asset.duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .task(id: assetVersion(asset)) {
                image = await CaptureLibrary.image(for: asset, size: CGSize(width: 300, height: 300))
            }
    }
}

/// Changes when the photo is edited, so views reload it.
private func assetVersion(_ asset: PHAsset) -> String {
    "\(asset.localIdentifier)-\(asset.modificationDate?.timeIntervalSince1970 ?? 0)"
}

private struct AssetViewer: View {
    @ObservedObject var library: CaptureLibrary
    @State var currentID: String
    @State private var editing: EditTarget?
    @Environment(\.dismiss) private var dismiss

    private struct EditTarget: Identifiable {
        let asset: PHAsset
        var id: String { asset.localIdentifier }
    }

    private var current: PHAsset? {
        library.assets.first { $0.localIdentifier == currentID }
    }

    var body: some View {
        TabView(selection: $currentID) {
            ForEach(library.assets, id: \.localIdentifier) { asset in
                AssetPage(asset: asset, isCurrent: asset.localIdentifier == currentID)
                    .tag(asset.localIdentifier)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .toolbarBackground(.visible, for: .bottomBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if let current, current.mediaType == .image {
                    Button {
                        editing = EditTarget(asset: current)
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    deleteCurrent()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .fullScreenCover(item: $editing) { target in
            PhotoEditor(asset: target.asset) { editing = nil }
        }
    }

    private func deleteCurrent() {
        guard let current, let index = library.assets.firstIndex(of: current) else { return }
        library.delete(current) { deleted in
            guard deleted else { return }
            let remaining = library.assets
            if remaining.isEmpty {
                dismiss()
            } else {
                currentID = remaining[min(index, remaining.count - 1)].localIdentifier
            }
        }
    }
}

private struct AssetPage: View {
    let asset: PHAsset
    let isCurrent: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView().tint(.white)
                }
            } else if let image {
                if image.images != nil {
                    AnimatedImage(image: image)  // GIFs play
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: assetVersion(asset)) {
            if asset.mediaType == .video {
                player = await loadPlayer()
            } else if asset.playbackStyle == .imageAnimated {
                image = await loadAnimated()
            } else {
                image = await CaptureLibrary.image(for: asset, size: CGSize(width: 2000, height: 2000),
                                                   mode: .aspectFit)
            }
        }
        .onChange(of: isCurrent) { _, isCurrent in
            if !isCurrent { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    private func loadAnimated() async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: frame))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        }
        return frames.count > 1 ? UIImage.animatedImage(with: frames, duration: duration) : frames.first
    }

    private func loadPlayer() async -> AVPlayer? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item.map { AVPlayer(playerItem: $0) })
            }
        }
    }
}

/// Plays an animated image (GIF). SwiftUI's Image only shows the first frame.
private struct AnimatedImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.image = image
        view.startAnimating()
    }
}
