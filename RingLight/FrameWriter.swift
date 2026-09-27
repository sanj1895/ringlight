import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Writes Core Image frames (and, for dual video, live microphone audio) to a .mov.
/// Used for boomerangs, timelapses and dual-camera videos.
final class FrameVideoWriter: @unchecked Sendable {  // all writing happens on its queue
    let url: URL
    let size: CGSize

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let realTime: Bool
    private let queue = DispatchQueue(label: "ringlight.writer")
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var startTime: CMTime?

    /// `realTime`: frames come live from the camera (late ones are dropped) rather than
    /// from a finished list (where the writer waits for each one).
    init?(size: CGSize, audio: Bool, realTime: Bool) {
        let width = Int(size.width) & ~1, height = Int(size.height) & ~1
        self.size = CGSize(width: width, height: height)
        self.realTime = realTime
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        self.writer = writer

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = realTime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            audioInput = input
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else { return nil }
    }

    /// Adds a frame at `time`. The image should cover (0, 0, size).
    func append(_ image: CIImage, at time: CMTime) {
        queue.sync {
            guard writer.status == .writing else { return }
            if startTime == nil {
                writer.startSession(atSourceTime: time)
                startTime = time
            }
            if realTime {
                guard videoInput.isReadyForMoreMediaData else { return }  // drop late frames
            } else {
                while !videoInput.isReadyForMoreMediaData { usleep(2_000) }
            }
            guard let pool = adaptor.pixelBufferPool else { return }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return }
            Look.context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
            adaptor.append(buffer, withPresentationTime: time)
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.async {
            guard let audioInput = self.audioInput, let startTime = self.startTime, self.writer.status == .writing,
                  sample.presentationTimeStamp >= startTime,
                  audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sample)
        }
    }

    /// Finishes the file. Returns its URL, or nil if nothing was written.
    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.startTime != nil, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                self.videoInput.markAsFinished()
                self.audioInput?.markAsFinished()
                self.writer.finishWriting {
                    continuation.resume(returning: self.writer.status == .completed ? self.url : nil)
                }
            }
        }
    }
}

enum GIFWriter {
    /// An endlessly looping animated GIF.
    static func make(frames: [CGImage], delay: Double) -> Data? {
        let data = NSMutableData()
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
                                                                 frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
