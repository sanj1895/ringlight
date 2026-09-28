import CoreImage
import CoreMotion
import UIKit
import UserNotifications

/// SHAKE mode's prints: every shot comes out blank and develops as you shake the phone.
/// Undeveloped prints wait here, in the app's own storage, until you develop them.
final class PrintTray: ObservableObject {
    static let shared = PrintTray()

    struct Print: Identifiable, Equatable {
        let url: URL
        let taken: Date
        var id: String { url.lastPathComponent }
    }

    /// Prints still waiting to be developed, oldest first.
    @Published private(set) var waiting: [Print] = []
    /// The print that's out on screen right now.
    @Published var front: Print?
    /// A print that was just taken and is still coming out of the camera's slot.
    @Published var ejecting: String?

    private let folder: URL
    private let progressKey = "printProgress"

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Prints", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        moveOldFilmRoll(from: documents.appendingPathComponent("FilmRoll", isDirectory: true))
        reload()
    }

    /// Adds a finished (still hidden) photo and puts it out on screen, blank.
    @discardableResult
    func add(_ jpeg: Data, taken: Date = Date()) -> Print {
        let url = folder.appendingPathComponent("\(Int(taken.timeIntervalSince1970))-\(UUID().uuidString).jpg")
        try? jpeg.write(to: url)
        let print = Print(url: url, taken: taken)
        DispatchQueue.main.async {
            self.reload()
            self.ejecting = print.id
            self.front = print
        }
        return print
    }

    /// Takes the next print off the pile.
    func pickUp() {
        front = waiting.first { $0 != front } ?? waiting.first
    }

    func progress(of print: Print) -> Double {
        (UserDefaults.standard.dictionary(forKey: progressKey)?[print.id] as? Double) ?? 0
    }

    func setProgress(_ progress: Double, for print: Print) {
        var all = UserDefaults.standard.dictionary(forKey: progressKey) ?? [:]
        all[print.id] = progress
        UserDefaults.standard.set(all, forKey: progressKey)
    }

    /// Called once a developed print is safely in the camera roll.
    func remove(_ print: Print) {
        try? FileManager.default.removeItem(at: print.url)
        var all = UserDefaults.standard.dictionary(forKey: progressKey) ?? [:]
        all[print.id] = nil
        UserDefaults.standard.set(all, forKey: progressKey)
        if front == print { front = nil }
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        waiting = files.compactMap { url in
            guard let seconds = url.lastPathComponent.split(separator: "-").first.flatMap({ TimeInterval($0) }) else {
                return nil
            }
            return Print(url: url, taken: Date(timeIntervalSince1970: seconds))
        }
        .sorted { $0.taken < $1.taken }
    }

    /// Shots from the old next-morning film roll become undeveloped prints, and its
    /// "your film is developed" notifications are cancelled.
    private func moveOldFilmRoll(from old: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        }
        try? FileManager.default.removeItem(at: old)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

/// Develops the print that's out on screen while you shake the phone:
/// the harder you shake, the faster it comes in.
final class PrintDeveloper: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var progress: Double = 0

    /// Called when a print finishes developing.
    var onDeveloped: ((PrintTray.Print) -> Void)?

    private var print: PrintTray.Print?
    private var photo: CIImage?
    private let motion = CMMotionManager()
    private let haptics = UIImpactFeedbackGenerator(style: .soft)
    private var lastRendered = -1.0
    private var lastSaved = 0.0

    func show(_ print: PrintTray.Print?) {
        guard print != self.print else { return }
        save()
        motion.stopDeviceMotionUpdates()
        self.print = print
        guard let print, let data = try? Data(contentsOf: print.url), let full = CIImage(data: data) else {
            photo = nil
            image = nil
            return
        }
        photo = full.scaledDown(toLongSide: 900)
        progress = PrintTray.shared.progress(of: print)
        lastSaved = progress
        render()
        guard progress < 1, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.userAcceleration else { return }
            self.shook((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot(), for: self.motion.deviceMotionUpdateInterval)
        }
    }

    /// `strength` is in g, not counting gravity. A good shake is around 1.5 g.
    private func shook(_ strength: Double, for seconds: Double) {
        guard let print, progress < 1, strength > 0.35 else { return }
        let before = progress
        progress = min(1, progress + (strength - 0.35) * seconds * 0.22)  // ~4 s of solid shaking
        if Int(progress * 10) > Int(before * 10) { haptics.impactOccurred(intensity: 0.6) }
        if progress - lastRendered > 0.01 || progress >= 1 { render() }
        if progress - lastSaved > 0.05 { save() }
        if progress >= 1 {
            save()
            motion.stopDeviceMotionUpdates()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onDeveloped?(print)
        }
    }

    private func save() {
        guard let print else { return }
        PrintTray.shared.setProgress(progress, for: print)
        lastSaved = progress
    }

    private func render() {
        guard let photo else { return }
        lastRendered = progress
        let developing = Self.developing(photo, progress: progress)
        if let cg = Look.context.createCGImage(developing, from: developing.extent) {
            image = UIImage(cgImage: cg)
        }
    }

    /// Instant film comes in dark and empty, then ghostly and blue-green, then the real colors arrive.
    static func developing(_ photo: CIImage, progress: Double) -> CIImage {
        let extent = photo.extent
        let blank = CIImage(color: CIColor(red: 0.13, green: 0.14, blue: 0.12)).cropped(to: extent)
        let ghost = photo
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 0.15, "inputContrast": 0.55, "inputBrightness": 0.08,
            ])
            .applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -0.03, y: 0.02, z: 0.07, w: 0)])
        func blend(_ from: CIImage, _ to: CIImage, _ t: Double) -> CIImage {
            let eased = t * t * (3 - 2 * t)
            return from.applyingFilter("CIDissolveTransition", parameters: [
                "inputTargetImage": to, "inputTime": eased,
            ]).cropped(to: extent)
        }
        return progress < 0.5 ? blend(blank, ghost, progress / 0.5) : blend(ghost, photo, (progress - 0.5) / 0.5)
    }
}
