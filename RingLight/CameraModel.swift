import AVFoundation
import CoreImage
import Photos
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "PHOTO"
    case video = "VIDEO"
    case portrait = "PORTRAIT"
    case dual = "DUAL"
    case dualVideo = "DUAL VIDEO"
    case booth = "BOOTH"
    case collage = "COLLAGE"
    case burst = "BURST"
    case boomerang = "BOOMERANG"
    case gif = "GIF"
    case slomo = "SLO-MO"
    case timelapse = "TIMELAPSE"

    var id: String { rawValue }
    var isDual: Bool { self == .dual || self == .dualVideo }
    /// Started and stopped with the shutter (red button).
    var records: Bool { [.video, .slomo, .timelapse, .dualVideo].contains(self) }
    /// Uses the tall 9:16 video camera setup.
    var isTall: Bool { [.video, .slomo, .timelapse, .boomerang, .dualVideo].contains(self) }
    /// The self-timer applies (booth and collage have their own countdown; burst is hold-to-shoot).
    var usesTimer: Bool { ![.booth, .collage, .burst].contains(self) }
}

/// The back camera's LED flash.
enum FlashSetting: CaseIterable {
    case off, auto, on

    var next: FlashSetting {
        switch self {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }
}

/// A burst shot waiting to be kept or thrown away.
struct BurstShot: Identifiable {
    let id = UUID()
    let data: Data
    let thumbnail: UIImage
}

/// The newest camera frame (and portrait mask), handed from the camera to the preview and captures.
final class FrameBox {
    private let lock = NSLock()
    private var image: CIImage?
    private var mask: CIImage?
    private var needsMask = false

    var latest: CIImage? {
        lock.lock(); defer { lock.unlock() }
        return image
    }

    var snapshot: (image: CIImage, mask: CIImage?)? {
        lock.lock(); defer { lock.unlock() }
        return image.map { ($0, mask) }
    }

    var wantsMask: Bool {
        get { lock.lock(); defer { lock.unlock() }; return needsMask }
        set { lock.lock(); needsMask = newValue; if !newValue { mask = nil }; lock.unlock() }
    }

    func set(_ image: CIImage, mask: CIImage?) {
        lock.lock(); self.image = image; self.mask = mask; lock.unlock()
    }
}

/// Owns the cameras, runs every capture mode, and saves the results to the camera roll.
final class CameraModel: NSObject, ObservableObject, @unchecked Sendable {  // state is guarded by its queues and locks
    /// Save selfies mirrored, so they look exactly like the preview.
    static let mirrorSelfies = true

    let session = AVCaptureSession()
    let frames = FrameBox()
    private let dual = DualCamera()

    // MARK: Settings

    @Published private(set) var mode: CaptureMode = .photo
    @Published var look: Look = .digicam
    @Published var dateStamp = false
    /// Self-timer in seconds: 0, 3 or 10.
    @Published var timer = 0
    /// Back camera only: a real flash for photos, and a steady light for everything else.
    @Published var flash: FlashSetting = .off
    @Published var collageCount = 4
    @Published var dualLayout: DualLayout = .pip
    /// Where the selfie bubble sits in PiP, 0...1 with y pointing down.
    @Published var pipCenter = CGPoint(x: 0.78, y: 0.2)
    @Published private(set) var isFront = true
    @Published private(set) var ultraWide = false

    // MARK: State

    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?
    /// A timer, booth, collage, burst, GIF or boomerang is in progress.
    @Published private(set) var busy = false
    @Published private(set) var countdown: Int?
    /// Small status shown on the preview, like "2/4" or "12".
    @Published private(set) var progress: String?
    @Published var burstShots: [BurstShot] = []
    @Published private(set) var toast: String?
    @Published private(set) var cameraDenied = false
    /// Goes up every time a shot is taken, so the screen can blink.
    @Published private(set) var shotCount = 0

    // MARK: Camera plumbing

    private let sessionQueue = DispatchQueue(label: "ringlight.session")
    private let frameQueue = DispatchQueue(label: "ringlight.frames")
    private let workQueue = DispatchQueue(label: "ringlight.work", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var camera: AVCaptureDevice?
    private var baseConfigured = false
    private var micGranted = false
    private var usingFront = true      // sessionQueue
    private var colorLocked = false    // sessionQueue
    private var slowMotionFPS: Double = 30  // sessionQueue
    private let liveSegmenter = PersonSegmenter(quality: .balanced)  // frameQueue

    // Jobs in flight
    private let jobsLock = NSLock()
    private var photoJobs: [Int64: PhotoJob] = [:]
    private var movieJob: MovieJob?
    private var cancelCountdown = false
    private var burstFrames: [Data] = []        // workQueue
    private var burstTimer: DispatchSourceTimer?
    private var timelapse: (writer: FrameVideoWriter, timer: DispatchSourceTimer)?
    private var timelapseIndex: Int64 = 0      // workQueue
    private var dualWriter: FrameVideoWriter?
    private var toastWork: DispatchWorkItem?

    private struct PhotoJob { let look: Look; let stamp: Date?; let portrait: Bool }
    private struct MovieJob { let look: Look; let stamp: Date?; let slowdown: Double? }
    private struct SessionPlan { let mode: CaptureMode; let front: Bool; let ultraWide: Bool }

    private var stampDate: Date? { dateStamp ? Date() : nil }

    /// The flash is the back camera's LED (the front camera has the ring light).
    var flashAvailable: Bool { !isFront && !mode.isDual }

    /// Shape of the preview and of what gets saved (width / height).
    var previewAspect: CGFloat {
        switch mode {
        case .booth: 1
        case .collage: Collage.cellAspect(forCollageOf: collageCount)
        default: mode.isTall ? 9.0 / 16.0 : 3.0 / 4.0
        }
    }

    // MARK: - Session lifecycle

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraDenied = !granted
                if granted { self.applyPlan() }
            }
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        if burstTimer != nil { stopBurst() }
        cancelCountdown = true
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.dual.stop()
        }
    }

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording, !busy else { return }
        if newMode.isDual, !DualCamera.isSupported {
            showToast("Dual camera isn't supported on this phone")
            return
        }
        mode = newMode
        if newMode == .video || newMode.isDual {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.micGranted = granted
                    self.applyPlan()
                }
            }
        } else {
            applyPlan()
        }
    }

    func flipCamera() {
        guard !isRecording, !busy, !mode.isDual else { return }
        isFront.toggle()
        ultraWide = false
        applyPlan()
    }

    /// 0.5× (back ultra-wide) ↔ 1×.
    func toggleUltraWide() {
        guard !isFront, !isRecording, !busy, !mode.isDual else { return }
        ultraWide.toggle()
        applyPlan()
    }

    private func applyPlan() {
        let plan = SessionPlan(mode: mode, front: isFront, ultraWide: ultraWide)
        let mic = micGranted
        sessionQueue.async { self.reconfigure(plan, mic: mic) }
    }

    /// Sets the camera up for a mode. Runs on the session queue.
    private func reconfigure(_ plan: SessionPlan, mic: Bool) {
        if plan.mode.isDual {
            if session.isRunning { session.stopRunning() }
            if !dual.start(withAudio: mic) {
                showToast("Dual camera isn't available right now")
            }
            return
        }
        dual.stop()

        session.beginConfiguration()
        if !baseConfigured {
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .quality
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            baseConfigured = true
        }

        // The camera: front, back, or back ultra-wide (0.5×).
        let position: AVCaptureDevice.Position = plan.front ? .front : .back
        let type: AVCaptureDevice.DeviceType = !plan.front && plan.ultraWide ? .builtInUltraWideCamera : .builtInWideAngleCamera
        var cameraChanged = false
        if camera?.position != position || camera?.deviceType != type,
           let device = AVCaptureDevice.default(type, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device) {
            if let old = videoInput { session.removeInput(old) }
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                camera = device
                cameraChanged = true
            } else if let old = videoInput {
                session.addInput(old)
            }
        }
        usingFront = camera?.position == .front

        session.sessionPreset = plan.mode.isTall ? .high : .photo

        let wantsMovie = plan.mode == .video || plan.mode == .slomo
        if wantsMovie, !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        } else if !wantsMovie, session.outputs.contains(movieOutput) {
            session.removeOutput(movieOutput)
        }

        let wantsMic = plan.mode == .video && mic
        if wantsMic, audioInput == nil, let device = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        } else if !wantsMic, let input = audioInput {
            session.removeInput(input)
            audioInput = nil
        }
        session.commitConfiguration()

        slowMotionFPS = plan.mode == .slomo ? useSlowMotionFormat() : 30
        prepare(videoOutput.connection(with: .video))
        frames.wantsMask = plan.mode == .portrait
        if cameraChanged { relockColorAfterSwitch() }
        if !session.isRunning { session.startRunning() }
    }

    /// The fastest 1080p format (up to 240 fps). Returns its frame rate.
    private func useSlowMotionFormat() -> Double {
        guard let camera else { return 30 }
        func maxRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        let formats = camera.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == 1920 && d.height == 1080 && maxRate($0) >= 60
        }
        guard let best = formats.max(by: { maxRate($0) < maxRate($1) }),
              (try? camera.lockForConfiguration()) != nil else { return 30 }
        let fps = min(maxRate(best), 240)
        camera.activeFormat = best
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        camera.activeVideoMinFrameDuration = duration
        camera.activeVideoMaxFrameDuration = duration
        camera.unlockForConfiguration()
        return fps
    }

    /// Portrait orientation + selfie mirroring for whatever we're about to capture.
    private func prepare(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            // Only selfies are mirrored; the back camera shows the world the right way round.
            connection.isVideoMirrored = Self.mirrorSelfies && usingFront
        }
    }

    // MARK: - Ring light color

    /// The camera normally auto-corrects color, which erases a pink or blue light on
    /// your face. With a colored ring we freeze the color balance at how things looked
    /// under white light, so the tint shows in the preview and in the photo.
    func setColoredLight(_ colored: Bool) {
        sessionQueue.async {
            guard colored != self.colorLocked else { return }
            self.colorLocked = colored
            guard let camera = self.camera, (try? camera.lockForConfiguration()) != nil else { return }
            if colored, camera.isWhiteBalanceModeSupported(.locked) {
                camera.setWhiteBalanceModeLocked(with: Self.clamped(camera.deviceWhiteBalanceGains, for: camera),
                                                 completionHandler: nil)
            } else if !colored, camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.unlockForConfiguration()
        }
    }

    /// A new camera needs a moment to find its own neutral color before we lock it.
    private func relockColorAfterSwitch() {
        guard colorLocked, let camera, (try? camera.lockForConfiguration()) != nil else { return }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        camera.unlockForConfiguration()
        sessionQueue.asyncAfter(deadline: .now() + 0.8) {
            guard self.colorLocked, self.camera === camera,
                  camera.isWhiteBalanceModeSupported(.locked),
                  (try? camera.lockForConfiguration()) != nil else { return }
            camera.setWhiteBalanceModeLocked(with: Self.clamped(camera.deviceWhiteBalanceGains, for: camera),
                                             completionHandler: nil)
            camera.unlockForConfiguration()
        }
    }

    private static func clamped(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                for camera: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        func clamp(_ g: Float) -> Float { min(max(g, 1), camera.maxWhiteBalanceGain) }
        return AVCaptureDevice.WhiteBalanceGains(redGain: clamp(gains.redGain),
                                                 greenGain: clamp(gains.greenGain),
                                                 blueGain: clamp(gains.blueGain))
    }

    // MARK: - What the camera sees

    /// Returns what the camera sees right now, exactly as the preview shows it (before the
    /// look). The current settings are captured, so it's safe to call from any thread.
    func frameSource(canvasWidth: CGFloat = 1080) -> () -> CIImage? {
        let mode = mode, layout = dualLayout, pip = pipCenter, aspect = previewAspect
        let frames = frames, dual = dual
        return {
            if mode.isDual {
                guard let back = dual.back.latest, let front = dual.front.latest else { return nil }
                let canvas = CGSize(width: canvasWidth, height: (canvasWidth / aspect).rounded())
                return DualCamera.compose(back: back, front: front, layout: layout, pip: pip, canvas: canvas)
            }
            guard let snapshot = frames.snapshot else { return nil }
            var frame = snapshot.image
            if mode == .portrait, let mask = snapshot.mask {
                frame = PersonSegmenter.blurBackground(frame, mask: mask)
            }
            return frame.centerCropped(toAspect: aspect)
        }
    }

    /// Copies the current picture out as a JPEG, so it can be kept. Runs on the work queue.
    private func grab(_ source: @escaping () -> CIImage?, longSide: CGFloat) async -> Data? {
        await withCheckedContinuation { continuation in
            workQueue.async {
                guard let frame = source(), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                    return continuation.resume(returning: nil)
                }
                let data = Look.context.jpegRepresentation(of: frame.scaledDown(toLongSide: longSide), colorSpace: space,
                                                           options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Shutter

    /// Shutter pressed (on-screen button or a volume button).
    func shutterDown() {
        if mode == .burst, !busy { startBurst() }
    }

    /// Shutter released.
    func shutterUp() {
        if mode == .burst {
            if burstTimer != nil { stopBurst() }
            return
        }
        if countdown != nil {
            cancelCountdown = true
            return
        }
        if isRecording {
            stopRecording()
            return
        }
        guard !busy else { return }
        Task { @MainActor in
            if mode.usesTimer, timer > 0 {
                busy = true
                let go = await runCountdown(timer)
                busy = false
                guard go else { return }
            }
            switch mode {
            case .photo, .portrait: capturePhoto()
            case .dual: captureDualPhoto()
            case .video, .slomo: startMovie()
            case .timelapse: startTimelapse()
            case .dualVideo: startDualVideo()
            case .booth: await runSequence(shots: 4, firstWait: 3, wait: 3, booth: true)
            case .collage: await runSequence(shots: collageCount, firstWait: 3, wait: 2, booth: false)
            case .boomerang: await runBoomerang()
            case .gif: await runGIF()
            case .burst: break
            }
        }
    }

    @MainActor private func runCountdown(_ seconds: Int) async -> Bool {
        cancelCountdown = false
        for n in stride(from: seconds, through: 1, by: -1) {
            countdown = n
            try? await Task.sleep(for: .seconds(1))
            if cancelCountdown {
                countdown = nil
                return false
            }
        }
        countdown = nil
        return true
    }

    // MARK: Photo, portrait, dual photo

    private func capturePhoto() {
        let job = PhotoJob(look: look, stamp: stampDate, portrait: mode == .portrait)
        let flashMode: AVCaptureDevice.FlashMode = !flashAvailable ? .off : flash == .on ? .on : flash == .auto ? .auto : .off
        shotCount += 1
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.prepare(self.photoOutput.connection(with: .video))
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            if flashMode != .off, self.photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            self.jobsLock.lock(); self.photoJobs[settings.uniqueID] = job; self.jobsLock.unlock()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func captureDualPhoto() {
        let source = frameSource(canvasWidth: 1440)
        let look = look, stamp = stampDate
        shotCount += 1
        workQueue.async {
            guard let image = source(), let data = look.jpeg(look.finishPhoto(image, stamp: stamp)) else {
                return self.showToast("Couldn't take photo")
            }
            self.savePhoto(data)
        }
    }

    // MARK: Torch

    /// For video and the multi-shot modes, the back LED stays on as a light while shooting.
    /// Returns true if it's being turned on (it takes a moment to come up).
    @discardableResult
    private func setTorch(_ on: Bool) -> Bool {
        let turnOn = on && flash != .off && flashAvailable
        let onlyIfDark = flash == .auto
        sessionQueue.async {
            guard let camera = self.camera, camera.position == .back, camera.hasTorch,
                  (try? camera.lockForConfiguration()) != nil else { return }
            // Auto: only when the camera is struggling for light.
            let dark = camera.iso >= min(1000, camera.activeFormat.maxISO * 0.5)
            let mode: AVCaptureDevice.TorchMode = turnOn && (!onlyIfDark || dark) ? .on : .off
            if camera.isTorchModeSupported(mode) { camera.torchMode = mode }
            camera.unlockForConfiguration()
        }
        return turnOn
    }

    // MARK: Booth and collage

    @MainActor private func runSequence(shots count: Int, firstWait: Int, wait: Int, booth: Bool) async {
        busy = true
        setTorch(true)
        defer { busy = false; progress = nil; setTorch(false) }
        var shots: [Data] = []
        for index in 0..<count {
            progress = "\(index + 1)/\(count)"
            guard await runCountdown(index == 0 ? firstWait : wait) else { return }
            if let data = await grab(frameSource(), longSide: 1400) { shots.append(data) }
            shotCount += 1
        }
        let look = look, stamp = stampDate
        showToast(booth ? "Printing your strip…" : "Making your collage…")
        workQueue.async {
            let images = shots.compactMap { CIImage(data: $0) }
            guard images.count == count else { return self.showToast("Couldn't finish — try again") }
            let result = booth ? Collage.photoBooth(images, look: look, date: stamp)
                               : Collage.grid(images, look: look, stamp: stamp)
            guard let data = look.jpeg(result) else { return }
            self.savePhoto(data)
        }
    }

    // MARK: Burst

    private func startBurst() {
        busy = true
        setTorch(true)
        progress = "0"
        let source = frameSource()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now(), repeating: 0.12)
        timer.setEventHandler {
            guard self.burstFrames.count < 40, let frame = source(),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let data = Look.context.jpegRepresentation(of: frame.scaledDown(toLongSide: 1920), colorSpace: space,
                                                             options: [:]) else { return }
            self.burstFrames.append(data)
            let count = self.burstFrames.count
            DispatchQueue.main.async { self.progress = "\(count)" }
        }
        workQueue.async { self.burstFrames = [] }
        timer.resume()
        burstTimer = timer
    }

    private func stopBurst() {
        burstTimer?.cancel()
        burstTimer = nil
        setTorch(false)
        let look = look, stamp = stampDate
        workQueue.async {
            let raw = self.burstFrames
            self.burstFrames = []
            let shots: [BurstShot] = raw.compactMap { data in
                guard let image = CIImage(data: data),
                      let finished = look.jpeg(look.finishPhoto(image, stamp: stamp)),
                      let thumbnail = CaptureLibrary.thumbnail(photoData: finished) else { return nil }
                return BurstShot(data: finished, thumbnail: thumbnail)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.progress = nil
                self.burstShots = shots
            }
        }
    }

    /// Saves the burst shots you picked.
    func keepBurstShots(_ picked: [BurstShot]) {
        burstShots = []
        for shot in picked { savePhoto(shot.data) }
    }

    // MARK: Boomerang and GIF

    @MainActor private func runBoomerang() async {
        busy = true
        progress = "●"
        if setTorch(true) { try? await Task.sleep(for: .milliseconds(600)) }
        let source = frameSource()
        var captured: [Data] = []
        for _ in 0..<30 {  // 1.5 seconds at 20 fps
            let started = Date()
            if let data = await grab(source, longSide: 1280) { captured.append(data) }
            let rest = 0.05 - Date().timeIntervalSince(started)
            if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
        }
        setTorch(false)
        progress = nil
        busy = false
        shotCount += 1
        showToast("Making boomerang…")
        let look = look, stamp = stampDate
        workQueue.async {
            let images = captured.compactMap { CIImage(data: $0) }.map { look.apply(to: $0, stamp: stamp) }
            guard let first = images.first,
                  let writer = FrameVideoWriter(size: first.extent.size, audio: false, realTime: false) else { return }
            // Forward, then backward, three times.
            let loop = images + images.dropFirst().dropLast().reversed()
            var index: Int64 = 0
            for _ in 0..<3 {
                for image in loop {
                    writer.append(image, at: CMTime(value: index, timescale: 30))
                    index += 1
                }
            }
            Task {
                guard let url = await writer.finish() else { return self.showToast("Couldn't make boomerang") }
                self.saveVideo(url)
            }
        }
    }

    @MainActor private func runGIF() async {
        busy = true
        progress = "●"
        if setTorch(true) { try? await Task.sleep(for: .milliseconds(600)) }
        let source = frameSource()
        var captured: [Data] = []
        for _ in 0..<12 {  // 2 seconds, 6 frames a second: choppy on purpose
            let started = Date()
            if let data = await grab(source, longSide: 900) { captured.append(data) }
            let rest = 1.0 / 6 - Date().timeIntervalSince(started)
            if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
        }
        setTorch(false)
        progress = nil
        busy = false
        shotCount += 1
        let look = look, stamp = stampDate
        workQueue.async {
            let frames: [CGImage] = captured.compactMap { data in
                guard let image = CIImage(data: data) else { return nil }
                let small = look.apply(to: image.scaledDown(toLongSide: 640), stamp: stamp)
                return Look.context.createCGImage(small, from: small.extent)
            }
            guard let gif = GIFWriter.make(frames: frames, delay: 1.0 / 6) else {
                return self.showToast("Couldn't make GIF")
            }
            self.saveToPhotos(success: "GIF saved ✓", thumbnail: CaptureLibrary.thumbnail(photoData: gif)) { request in
                request.addResource(with: .photo, data: gif, options: nil)
            }
        }
    }

    // MARK: Video and slo-mo

    private func startMovie() {
        setTorch(true)
        let look = look, stamp = stampDate, slowMotion = mode == .slomo
        sessionQueue.async {
            guard self.session.isRunning, self.session.outputs.contains(self.movieOutput),
                  !self.movieOutput.isRecording else { return }
            self.prepare(self.movieOutput.connection(with: .video))
            let job = MovieJob(look: look, stamp: stamp, slowdown: slowMotion ? self.slowMotionFPS / 30 : nil)
            self.jobsLock.lock(); self.movieJob = job; self.jobsLock.unlock()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func stopRecording() {
        switch mode {
        case .video, .slomo:
            sessionQueue.async {
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            }
        case .timelapse: stopTimelapse()
        case .dualVideo: stopDualVideo()
        default: break
        }
    }

    // MARK: Timelapse

    private func startTimelapse() {
        guard let writer = FrameVideoWriter(size: CGSize(width: 1080, height: 1920), audio: false, realTime: false) else {
            return showToast("Couldn't start timelapse")
        }
        let source = frameSource(), look = look, stamp = stampDate
        let size = writer.size
        setTorch(true)
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now(), repeating: 0.5)  // 2 pictures a second, played at 30 fps = 15× speed
        timer.setEventHandler {
            guard let frame = source() else { return }
            let image = look.apply(to: frame.filling(CGRect(origin: .zero, size: size)), stamp: stamp)
            writer.append(image, at: CMTime(value: self.timelapseIndex, timescale: 30))
            self.timelapseIndex += 1
        }
        workQueue.async { self.timelapseIndex = 0 }
        timer.resume()
        timelapse = (writer, timer)
        isRecording = true
        recordingStart = Date()
    }

    private func stopTimelapse() {
        guard let current = timelapse else { return }
        let writer = current.writer
        timelapse = nil
        current.timer.cancel()
        setTorch(false)
        isRecording = false
        recordingStart = nil
        showToast("Saving timelapse…")
        workQueue.async {
            Task {
                guard let url = await writer.finish() else { return self.showToast("Timelapse was too short") }
                self.saveVideo(url)
            }
        }
    }

    // MARK: Dual video

    private func startDualVideo() {
        guard let writer = FrameVideoWriter(size: CGSize(width: 1080, height: 1920), audio: micGranted, realTime: true) else {
            return showToast("Couldn't start recording")
        }
        let source = frameSource(canvasWidth: writer.size.width), look = look, stamp = stampDate
        dual.onBackFrame { time in
            guard let frame = source() else { return }
            writer.append(look.apply(to: frame, stamp: stamp), at: time)
        }
        dual.onAudio { writer.appendAudio($0) }
        dualWriter = writer
        isRecording = true
        recordingStart = Date()
    }

    private func stopDualVideo() {
        dual.onBackFrame(nil)
        dual.onAudio(nil)
        guard let writer = dualWriter else { return }
        dualWriter = nil
        isRecording = false
        recordingStart = nil
        Task {
            guard let url = await writer.finish() else { return showToast("Recording failed") }
            saveVideo(url)
        }
    }

    // MARK: - Saving

    private func savePhoto(_ data: Data) {
        saveToPhotos(success: "Photo saved ✓", thumbnail: CaptureLibrary.thumbnail(photoData: data)) { request in
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    private func saveVideo(_ url: URL) {
        Task {
            let thumbnail = await CaptureLibrary.thumbnail(videoAt: url)
            saveToPhotos(success: "Video saved ✓", thumbnail: thumbnail,
                         cleanup: { _ = try? FileManager.default.removeItem(at: url) }) { request in
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }
        }
    }

    private func saveToPhotos(success: String,
                              thumbnail: UIImage?,
                              cleanup: (() -> Void)? = nil,
                              _ addResource: @escaping (PHAssetCreationRequest) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                cleanup?()
                self.showToast("Allow Photos access in Settings")
                return
            }
            var createdID: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                addResource(request)
                createdID = request.placeholderForCreatedAsset?.localIdentifier
            }) { saved, _ in
                cleanup?()
                // Remember it's ours, so it shows up in the in-app gallery.
                if saved, let createdID { CaptureLibrary.shared.add(id: createdID, thumbnail: thumbnail) }
                self.showToast(saved ? success : "Couldn't save")
            }
        }
    }

    private func showToast(_ message: String) {
        DispatchQueue.main.async {
            self.toastWork?.cancel()
            self.toast = message
            let work = DispatchWorkItem { self.toast = nil }
            self.toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        jobsLock.lock()
        let job = photoJobs.removeValue(forKey: photo.resolvedSettings.uniqueID)
            ?? PhotoJob(look: .normal, stamp: nil, portrait: false)
        jobsLock.unlock()
        guard error == nil, let data = photo.fileDataRepresentation() else {
            showToast("Couldn't take photo")
            return
        }
        workQueue.async {
            let processed = Look.processPhoto(data, look: job.look, stamp: job.stamp, portrait: job.portrait)
            self.savePhoto(processed ?? data)
        }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingStart = Date()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingStart = nil
            self.setTorch(false)
        }
        jobsLock.lock()
        let job = movieJob ?? MovieJob(look: .normal, stamp: nil, slowdown: nil)
        movieJob = nil
        jobsLock.unlock()

        // Some "errors" (e.g. hitting a size limit) still leave a usable file.
        var usable = true
        if let error = error as NSError? {
            usable = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        }
        guard usable else {
            try? FileManager.default.removeItem(at: outputFileURL)
            showToast("Recording failed")
            return
        }

        if job.look != .normal || job.stamp != nil || job.slowdown != nil {
            showToast(job.slowdown != nil ? "Slowing it down…" : "Adding \(job.look.name) look…")
        }
        Task {
            if let processed = await Look.processVideo(at: outputFileURL, look: job.look, stamp: job.stamp,
                                                       slowdown: job.slowdown) {
                if processed != outputFileURL { try? FileManager.default.removeItem(at: outputFileURL) }
                saveVideo(processed)
            } else {
                saveVideo(outputFileURL)  // keep the original rather than lose the video
            }
        }
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let mask = frames.wantsMask ? liveSegmenter.mask(for: image) : nil
        frames.set(image, mask: mask)
    }
}
