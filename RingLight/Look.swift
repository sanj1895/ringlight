import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// The looks you can shoot with. Each one is applied the same way to the live preview,
/// photos, videos, GIFs and strips, so what you see is what you get.
enum Look: String, CaseIterable, Identifiable, Codable {
    case normal, digicam, disposable, polaroid, camcorder, mono

    var id: String { rawValue }

    var name: String {
        switch self {
        case .normal: "Normal"
        case .digicam: "Digicam"
        case .disposable: "Disposable"
        case .polaroid: "Polaroid"
        case .camcorder: "Camcorder"
        case .mono: "B&W"
        }
    }

    var icon: String {
        switch self {
        case .normal: "camera"
        case .digicam: "camera.fill"
        case .disposable: "bolt.fill"
        case .polaroid: "photo"
        case .camcorder: "video.fill"
        case .mono: "circle.lefthalf.filled"
        }
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The resolution of the "sensor" this look pretends to have. This is where detail
    /// is lost, and it keeps the look the same on a preview frame and a 12 MP photo.
    private var sensorLongSide: CGFloat? {
        switch self {
        case .normal: nil
        case .digicam: 1600      // ~2 MP of real detail, like a 5 MP Coolpix
        case .disposable: 1500
        case .polaroid: 1400
        case .camcorder: 640     // standard-definition tape
        case .mono: 2400
        }
    }

    /// How big saved photos are (nil = the camera's full resolution).
    var photoLongSide: CGFloat? {
        switch self {
        case .normal, .mono: nil
        case .digicam: 2592      // 5 MP
        case .disposable: 2400
        case .polaroid: 2000
        case .camcorder: 1440
        }
    }

    private var jpegQuality: CGFloat {
        switch self {
        case .normal, .mono: 0.92
        default: 0.8             // everyday "Normal" JPEG quality
        }
    }

    // MARK: - Applying

    /// Applies the look, plus the date stamp if `stamp` is given. The result has the same
    /// size as the input unless `outputLongSide` is given (then it starts at the origin).
    func apply(to image: CIImage, outputLongSide: CGFloat? = nil, stamp: Date? = nil) -> CIImage {
        if self == .normal, stamp == nil, outputLongSide == nil { return image }
        let extent = image.extent
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let longSide = max(extent.width, extent.height)
        let outLong = outputLongSide ?? longSide

        var output: CIImage
        if let sensorLongSide {
            // Down to the "sensor", process, and back up: that spreads grain and softness out.
            let toSensor = min(1, sensorLongSide / longSide)
            let sensor = Self.resample(image.transformed(by: origin), by: toSensor)
            let up = outLong / (longSide * toSensor)
            output = process(sensor).transformed(by: CGAffineTransform(scaleX: up, y: up))
        } else {
            output = Self.resample(image.transformed(by: origin), by: outLong / longSide)
        }
        let outSize = CGSize(width: (extent.width * outLong / longSide).rounded(),
                             height: (extent.height * outLong / longSide).rounded())
        output = output.cropped(to: CGRect(origin: .zero, size: outSize))

        if self == .camcorder {
            output = Self.camcorderOverlay(on: output, date: stamp)
        } else if let stamp {
            output = Self.dateStamp(on: output, date: stamp)
        }
        if outputLongSide == nil {
            output = output.transformed(by: origin.inverted())
        }
        return output
    }

    /// A finished photo: the look at photo size, and the instant-photo border for Polaroid.
    func finishPhoto(_ image: CIImage, stamp: Date?) -> CIImage {
        let output = apply(to: image, outputLongSide: photoLongSide ?? max(image.extent.width, image.extent.height),
                           stamp: stamp)
        return self == .polaroid ? Self.polaroidFrame(output) : output
    }

    func jpeg(_ image: CIImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return Self.context.jpegRepresentation(of: image.settingProperties([:]), colorSpace: space, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality,
        ])
    }

    // MARK: - The looks

    private func process(_ image: CIImage) -> CIImage {
        let extent = image.extent
        var img = image.clampedToExtent()
        switch self {
        case .normal:
            return image

        case .digicam:
            // Mid-2000s CCD point-and-shoot (Nikon Coolpix): not over-sharpened, soft
            // blooming highlights, bright pastel-leaning color, gentle contrast.
            img = Self.fringe(img, extent: extent, red: Self.zoom(1.0025, extent), blue: Self.zoom(0.9975, extent))
            img = Self.sharpen(img, radius: 1.0, intensity: 0.25)
            img = Self.exposure(img, 0.12)
            img = Self.bloom(img, radius: 6, intensity: 0.3)
            img = Self.curve(img, [0.02, 0.24, 0.52, 0.79, 0.98])
            img = Self.vibrance(img, 0.35)
            img = Self.warmth(img, target: 6250, tint: 3)
            img = Self.vignette(img, 0.3)
            img = Self.grain(img, extent: extent, luma: 0.16, chroma: 0.06)

        case .disposable:
            // Cheap film camera with the flash on: warm, punchy, heavy grain, dark corners,
            // and a little orange light leak.
            img = img.applyingGaussianBlur(sigma: 0.8)
            img = Self.exposure(img, 0.15)
            img = Self.curve(img, [0.05, 0.22, 0.55, 0.83, 0.97])
            img = Self.saturation(img, 1.08, contrast: 1.04)
            img = Self.warmth(img, target: 5500, tint: 8)
            img = Self.vignette(img, 0.8, radius: 1.2)
            img = Self.lightLeak(img, extent: extent)
            img = Self.grain(img, extent: extent, luma: 0.26, chroma: 0.08)

        case .polaroid:
            // Instant film: soft, faded, lifted blacks, cool shadows and warm highlights.
            img = img.applyingGaussianBlur(sigma: 1.0)
            img = Self.curve(img, [0.1, 0.3, 0.54, 0.76, 0.92])
            img = Self.saturation(img, 0.85, contrast: 1)
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: -0.01, y: 0.012, z: 0.02, w: 0),
            ])
            img = Self.warmth(img, target: 6000, tint: 0)
            img = Self.vignette(img, 0.4)
            img = Self.grain(img, extent: extent, luma: 0.12, chroma: 0.04)

        case .camcorder:
            // VHS tape: soft SD picture, smeared color, edge halos, scanlines, noise.
            let smeared = CIFilter.motionBlur()
            smeared.inputImage = img
            smeared.radius = 3
            smeared.angle = 0
            if let blurred = smeared.outputImage {
                img = img.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": blurred, "inputTime": 0.4,
                ])
            }
            img = Self.fringe(img, extent: extent, red: CGAffineTransform(translationX: 1.5, y: 0),
                              blue: CGAffineTransform(translationX: -1, y: 0))
            img = Self.sharpen(img, radius: 2, intensity: 0.6)
            img = Self.curve(img, [0.06, 0.28, 0.53, 0.77, 0.95])
            img = Self.saturation(img, 1.25, contrast: 0.95)
            img = Self.warmth(img, target: 7000, tint: 0)
            img = Self.scanlines(img, extent: extent)
            img = Self.grain(img, extent: extent, luma: 0.18, chroma: 0.12)

        case .mono:
            // Black and white with a bit of punch and fine grain.
            img = Self.saturation(img, 0, contrast: 1.1)
            img = Self.curve(img, [0.02, 0.23, 0.52, 0.8, 0.98])
            img = Self.vignette(img, 0.3)
            img = Self.grain(img, extent: extent, luma: 0.14, chroma: 0)
        }
        return img.cropped(to: extent)
    }

    // MARK: - Building blocks

    private static func sharpen(_ image: CIImage, radius: Float, intensity: Float) -> CIImage {
        let f = CIFilter.unsharpMask()
        f.inputImage = image
        f.radius = radius
        f.intensity = intensity
        return f.outputImage ?? image
    }

    private static func exposure(_ image: CIImage, _ ev: Float) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = ev
        return f.outputImage ?? image
    }

    private static func bloom(_ image: CIImage, radius: Float, intensity: Float) -> CIImage {
        let f = CIFilter.bloom()
        f.inputImage = image
        f.radius = radius
        f.intensity = intensity
        return f.outputImage ?? image
    }

    /// Tone curve through (0, 0.25, 0.5, 0.75, 1) → `y`.
    private static func curve(_ image: CIImage, _ y: [CGFloat]) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = image
        f.point0 = CGPoint(x: 0, y: y[0])
        f.point1 = CGPoint(x: 0.25, y: y[1])
        f.point2 = CGPoint(x: 0.5, y: y[2])
        f.point3 = CGPoint(x: 0.75, y: y[3])
        f.point4 = CGPoint(x: 1, y: y[4])
        return f.outputImage ?? image
    }

    private static func vibrance(_ image: CIImage, _ amount: Float) -> CIImage {
        let f = CIFilter.vibrance()
        f.inputImage = image
        f.amount = amount
        return f.outputImage ?? image
    }

    private static func saturation(_ image: CIImage, _ saturation: Float, contrast: Float) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = saturation
        f.contrast = contrast
        return f.outputImage ?? image
    }

    /// Lower `target` = warmer.
    private static func warmth(_ image: CIImage, target: CGFloat, tint: CGFloat) -> CIImage {
        let f = CIFilter.temperatureAndTint()
        f.inputImage = image
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(x: target, y: tint)
        return f.outputImage ?? image
    }

    private static func vignette(_ image: CIImage, _ intensity: Float, radius: Float = 1.4) -> CIImage {
        let f = CIFilter.vignette()
        f.inputImage = image
        f.intensity = intensity
        f.radius = radius
        return f.outputImage ?? image
    }

    private static func zoom(_ scale: CGFloat, _ extent: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -extent.midX, y: -extent.midY)
    }

    /// Cheap-lens / tape color fringing: red and blue land in slightly different places.
    private static func fringe(_ image: CIImage, extent: CGRect,
                               red: CGAffineTransform, blue: CGAffineTransform) -> CIImage {
        // Opaque single-channel images, recombined with "maximum".
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        return channel(1, 0, 0).transformed(by: red)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(0, 1, 0)])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey:
                                                                    channel(0, 0, 1).transformed(by: blue)])
    }

    private static func lightLeak(_ image: CIImage, extent: CGRect) -> CIImage {
        let f = CIFilter.radialGradient()
        f.center = CGPoint(x: extent.maxX, y: extent.maxY)
        f.radius0 = 0
        f.radius1 = Float(max(extent.width, extent.height) * 0.7)
        f.color0 = CIColor(red: 1, green: 0.45, blue: 0.15, alpha: 0.4)
        f.color1 = CIColor(red: 1, green: 0.45, blue: 0.15, alpha: 0)
        guard let leak = f.outputImage?.cropped(to: extent) else { return image }
        return leak.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    private static func scanlines(_ image: CIImage, extent: CGRect) -> CIImage {
        let f = CIFilter.stripesGenerator()
        f.center = .zero
        f.color0 = CIColor(red: 1, green: 1, blue: 1)
        f.color1 = CIColor(red: 0.82, green: 0.82, blue: 0.82)
        f.width = 1
        f.sharpness = 0.6
        // The generator makes vertical stripes; turn them into horizontal lines.
        guard let lines = f.outputImage?.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)) else { return image }
        return lines.cropped(to: extent)
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image])
    }

    /// Sensor grain, a new pattern every frame like the real thing.
    private static func grain(_ image: CIImage, extent: CGRect, luma: CGFloat, chroma: CGFloat) -> CIImage {
        guard let random = CIFilter.randomGenerator().outputImage else { return image }
        let noise = random
            .transformed(by: CGAffineTransform(translationX: CGFloat(Int.random(in: 0..<2048)),
                                               y: CGFloat(Int.random(in: 0..<2048))))
            .cropped(to: extent)
            .settingAlphaOne(in: extent)
        // Gray grain texture (0.5 = no change), overlaid on the picture.
        let grain = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: luma, y: chroma, z: 0, w: 0),
            "inputGVector": CIVector(x: luma, y: 0, z: chroma, w: 0),
            "inputBVector": CIVector(x: luma, y: -chroma, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.5 - (luma + chroma) / 2, y: 0.5 - (luma + chroma) / 2,
                                        z: 0.5 - luma / 2 + chroma / 2, w: 1),
        ])
        return grain.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    /// Good-quality scaling when shrinking a lot (photos), cheap otherwise (live preview).
    static func resample(_ image: CIImage, by scale: CGFloat) -> CIImage {
        if scale == 1 { return image }
        guard scale < 0.75 else { return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(scale)
        f.aspectRatio = 1
        return f.outputImage ?? image
    }

    // MARK: - Date stamp, camcorder overlay, instant-photo frame

    private static let textCache = NSCache<NSString, CIImage>()

    /// Text drawn once into a bitmap and reused.
    static func text(_ string: String, font: UIFont, color: UIColor) -> CIImage {
        let key = "\(string)|\(font.fontName)|\(font.pointSize)|\(color.description)" as NSString
        if let cached = textCache.object(forKey: key) { return cached }
        let f = CIFilter.attributedTextImageGenerator()
        f.text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        f.scaleFactor = 1
        var image = f.outputImage ?? CIImage.empty()
        if let cg = context.createCGImage(image, from: image.extent) {
            image = CIImage(cgImage: cg)
        }
        textCache.setObject(image, forKey: key)
        return image
    }

    /// The classic orange digicam date ('26 9 25) in the bottom-right corner.
    private static func dateStamp(on image: CIImage, date: Date) -> CIImage {
        let extent = image.extent
        let size = (min(extent.width, extent.height) * 0.055).rounded()
        let font = UIFont(name: "DBLCDTempBlack", size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .bold)
        let formatter = DateFormatter()
        formatter.dateFormat = "''yy M d"
        let orange = UIColor(red: 1, green: 0.55, blue: 0.12, alpha: 1)
        let label = text(formatter.string(from: date), font: font, color: orange)
        let margin = min(extent.width, extent.height) * 0.05
        let place = CGAffineTransform(translationX: extent.maxX - margin - label.extent.width,
                                      y: extent.minY + margin)
        let stamp = label.transformed(by: place)
        let glow = stamp.clampedToExtent().applyingGaussianBlur(sigma: size * 0.12).cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.7)])
        return stamp.composited(over: glow.composited(over: image))
    }

    /// "PLAY ▶" in the corner, plus a VHS time and date when the date stamp is on.
    private static func camcorderOverlay(on image: CIImage, date: Date?) -> CIImage {
        let extent = image.extent
        let size = (min(extent.width, extent.height) * 0.05).rounded()
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let margin = min(extent.width, extent.height) * 0.06
        let shadowOffset = CGAffineTransform(translationX: size * 0.08, y: -size * 0.08)

        func label(_ string: String, at point: CGPoint, over base: CIImage) -> CIImage {
            let white = text(string, font: font, color: .white).transformed(by: CGAffineTransform(translationX: point.x, y: point.y))
            let shadow = text(string, font: font, color: UIColor(white: 0, alpha: 0.6))
                .transformed(by: CGAffineTransform(translationX: point.x, y: point.y).concatenating(shadowOffset))
            return white.composited(over: shadow.composited(over: base))
        }

        let play = text("PLAY ▶", font: font, color: .white)
        var output = label("PLAY ▶", at: CGPoint(x: extent.minX + margin, y: extent.maxY - margin - play.extent.height),
                           over: image)
        if let date {
            let time = DateFormatter()
            time.dateFormat = "h:mm a"
            let day = DateFormatter()
            day.dateFormat = "MMM. d yyyy"
            let dayText = day.string(from: date).uppercased()
            let line = text(dayText, font: font, color: .white).extent.height
            output = label(dayText, at: CGPoint(x: extent.minX + margin, y: extent.minY + margin), over: output)
            output = label(time.string(from: date), at: CGPoint(x: extent.minX + margin, y: extent.minY + margin + line * 1.1),
                           over: output)
        }
        return output.cropped(to: extent)
    }

    /// The white instant-photo border (Instax Mini proportions), with the thick bottom.
    static func polaroidFrame(_ image: CIImage) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        let side = (w * 0.087).rounded(), top = (w * 0.15).rounded(), bottom = (w * 0.37).rounded()
        let card = CIImage(color: CIColor(red: 0.96, green: 0.95, blue: 0.92))
            .cropped(to: CGRect(x: 0, y: 0, width: w + side * 2, height: h + top + bottom))
        let photo = image.transformed(by: CGAffineTransform(translationX: side - image.extent.minX,
                                                            y: bottom - image.extent.minY))
        return photo.composited(over: card)
    }

    // MARK: - Photos and videos

    /// A camera photo with the look, date stamp and (optionally) portrait blur, as JPEG.
    /// Returns the original data untouched when there's nothing to do.
    static func processPhoto(_ data: Data, look: Look, stamp: Date?, portrait: Bool) -> Data? {
        if look == .normal, stamp == nil, !portrait { return data }
        guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        if portrait, let mask = PersonSegmenter(quality: .accurate).mask(for: image) {
            image = PersonSegmenter.blurBackground(image, mask: mask)
        }
        return look.jpeg(look.finishPhoto(image, stamp: stamp))
    }

    /// A recorded video with the look and date stamp, and slowed down for slo-mo.
    /// Returns the original file when there's nothing to do, nil on failure.
    static func processVideo(at url: URL, look: Look, stamp: Date?, slowdown: Double?) async -> URL? {
        let needsLook = look != .normal || stamp != nil
        let slow = (slowdown ?? 1) > 1.01
        guard needsLook || slow else { return url }

        let original = AVURLAsset(url: url)
        var source: AVAsset = original
        do {
            if slow, let slowdown {
                // Stretch the high-frame-rate recording so it plays back in slow motion.
                guard let track = try await original.loadTracks(withMediaType: .video).first else { return nil }
                let duration = try await original.load(.duration)
                let composition = AVMutableComposition()
                guard let slowTrack = composition.addMutableTrack(withMediaType: .video,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
                let range = CMTimeRange(start: .zero, duration: duration)
                try slowTrack.insertTimeRange(range, of: track, at: .zero)
                slowTrack.preferredTransform = try await track.load(.preferredTransform)
                slowTrack.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: slowdown))
                source = composition
            }

            guard let export = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetHighestQuality) else {
                return nil
            }
            if needsLook {
                let filtered = try await AVVideoComposition.videoComposition(with: source) { request in
                    request.finish(with: look.apply(to: request.sourceImage, stamp: stamp), context: context)
                }
                let composition = filtered.mutableCopy() as! AVMutableVideoComposition
                composition.frameDuration = CMTime(value: 1, timescale: 30)
                export.videoComposition = composition
            }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            try await export.export(to: output, as: .mov)
            return output
        } catch {
            return nil
        }
    }
}

extension CIImage {
    /// The biggest centered piece of the image with this shape (width / height), moved to the origin.
    func centerCropped(toAspect aspect: CGFloat) -> CIImage {
        let e = extent
        var crop = e
        if e.width / e.height > aspect {
            crop.size.width = e.height * aspect
            crop.origin.x = e.midX - crop.width / 2
        } else {
            crop.size.height = e.width / aspect
            crop.origin.y = e.midY - crop.height / 2
        }
        return cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// Scaled to fill `rect` (cropping any overflow) and placed in it.
    func filling(_ rect: CGRect) -> CIImage {
        let piece = centerCropped(toAspect: rect.width / rect.height)
        let scale = rect.width / piece.extent.width
        return Look.resample(piece, by: scale)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
    }

    /// Scaled so the long side is at most `longSide`, starting at the origin.
    func scaledDown(toLongSide longSide: CGFloat) -> CIImage {
        let moved = transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = min(1, longSide / max(extent.width, extent.height))
        return Look.resample(moved, by: scale)
    }
}
