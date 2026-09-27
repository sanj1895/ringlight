import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

enum DualLayout: String, CaseIterable {
    case pip = "PiP"
    case split = "Split"
}

/// Front and back cameras at the same time (BeReal / Snapchat dual camera).
/// Runs its own multi-camera session; the normal session is stopped while it runs.
final class DualCamera: NSObject {
    static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    let session = AVCaptureMultiCamSession()
    let back = FrameBox()
    let front = FrameBox()

    private let backOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "ringlight.dual")
    private let lock = NSLock()
    private var backFrameHandler: ((CMTime) -> Void)?
    private var audioHandler: ((CMSampleBuffer) -> Void)?
    private var configured = false

    /// Called for every back-camera frame (drives dual video recording).
    func onBackFrame(_ handler: ((CMTime) -> Void)?) {
        lock.lock(); backFrameHandler = handler; lock.unlock()
    }

    func onAudio(_ handler: ((CMSampleBuffer) -> Void)?) {
        lock.lock(); audioHandler = handler; lock.unlock()
    }

    /// Call on the camera queue. Returns false if dual camera can't run.
    func start(withAudio: Bool) -> Bool {
        guard Self.isSupported else { return false }
        if !configured {
            configured = configure(withAudio: withAudio)
            guard configured else { return false }
        }
        if !session.isRunning { session.startRunning() }
        return true
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    private func configure(withAudio: Bool) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for (position, output) in [(AVCaptureDevice.Position.back, backOutput), (.front, frontOutput)] {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return false }
            session.addInputWithNoConnections(input)
            useMultiCamFormat(device)

            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { return false }
            session.addOutputWithNoConnections(output)

            guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                         sourceDevicePosition: position).first else { return false }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { return false }
            session.addConnection(connection)
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front && CameraModel.mirrorSelfies
            }
        }

        if withAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInputWithNoConnections(input)
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audioOutput) {
                session.addOutputWithNoConnections(audioOutput)
                if let port = input.ports(for: .audio, sourceDeviceType: mic.deviceType,
                                          sourceDevicePosition: .front).first {
                    let connection = AVCaptureConnection(inputPorts: [port], output: audioOutput)
                    if session.canAddConnection(connection) { session.addConnection(connection) }
                }
            }
        }
        return true
    }

    /// The largest 4:3 format that can run alongside the other camera (up to 1920 wide).
    private func useMultiCamFormat(_ device: AVCaptureDevice) {
        let formats = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.isMultiCamSupported && d.width <= 1920 && d.width * 3 == d.height * 4
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        guard let best = formats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }), (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = best
        device.unlockForConfiguration()
    }

    // MARK: - Composing

    /// Both cameras in one picture of `canvas` size.
    /// PiP: back camera full, your selfie in a rounded bubble centered at `pip` (0...1, y down).
    /// Split: you on top, what you're looking at on the bottom.
    static func compose(back: CIImage, front: CIImage, layout: DualLayout, pip: CGPoint, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        switch layout {
        case .pip:
            let base = back.filling(bounds)
            let rect = pipRect(center: pip, canvas: canvas)
            let bubble = front.filling(rect)
            let radius = rect.width * 0.12

            let shape = CIFilter.roundedRectangleGenerator()
            shape.extent = rect
            shape.radius = Float(radius)
            shape.color = .white
            let blend = CIFilter.blendWithMask()
            blend.inputImage = bubble
            blend.backgroundImage = base
            blend.maskImage = shape.outputImage
            var output = blend.outputImage ?? base

            let border = CIFilter.roundedRectangleStrokeGenerator()
            border.extent = rect
            border.radius = Float(radius)
            border.width = Float(rect.width * 0.02)
            border.color = CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)
            if let ring = border.outputImage { output = ring.composited(over: output) }
            return output.cropped(to: bounds)

        case .split:
            let half = canvas.height / 2
            let top = front.filling(CGRect(x: 0, y: half, width: canvas.width, height: half))
            let bottom = back.filling(CGRect(x: 0, y: 0, width: canvas.width, height: half))
            let line = CIImage(color: .white).cropped(to: CGRect(x: 0, y: half - canvas.height * 0.002,
                                                                 width: canvas.width, height: canvas.height * 0.004))
            return line.composited(over: top.composited(over: bottom)).cropped(to: bounds)
        }
    }

    /// The selfie bubble: a third of the width, kept fully on screen.
    static func pipRect(center: CGPoint, canvas: CGSize) -> CGRect {
        let width = canvas.width * 0.32, height = width * 4 / 3
        let margin = canvas.width * 0.04
        let x = min(max(center.x * canvas.width - width / 2, margin), canvas.width - width - margin)
        let yDown = min(max(center.y * canvas.height - height / 2, margin), canvas.height - height - margin)
        return CGRect(x: x, y: canvas.height - yDown - height, width: width, height: height)  // y up
    }
}

extension DualCamera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            lock.lock(); let handler = audioHandler; lock.unlock()
            handler?(sampleBuffer)
            return
        }
        guard let pixels = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        if output === frontOutput {
            front.set(image, mask: nil)
        } else {
            back.set(image, mask: nil)
            lock.lock(); let handler = backFrameHandler; lock.unlock()
            handler?(sampleBuffer.presentationTimeStamp)
        }
    }
}
