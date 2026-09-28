import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Backdrop mode: you, cut out and placed in front of one of these.
enum Backdrop: String, CaseIterable, Identifiable {
    case schoolPhoto, laser, pinkStudio, sky, yourPhoto

    var id: String { rawValue }

    static let builtIn: [Backdrop] = [.schoolPhoto, .laser, .pinkStudio, .sky]

    var name: String {
        switch self {
        case .schoolPhoto: "Picture day"
        case .laser: "Lasers"
        case .pinkStudio: "Pink studio"
        case .sky: "Sky"
        case .yourPhoto: "Your photo"
        }
    }

    private static let size = CGSize(width: 1440, height: 1920)
    private static let cacheLock = NSLock()
    private static var cache: [Backdrop: CIImage] = [:]

    /// The backdrop picture (drawn once, then reused). `yourPhoto` needs `custom`.
    func image(custom: CIImage?) -> CIImage? {
        if self == .yourPhoto { return custom }
        Self.cacheLock.lock(); defer { Self.cacheLock.unlock() }
        if let cached = Self.cache[self] { return cached }
        // Render once into a bitmap, so the live preview doesn't redo the drawing every frame.
        guard let drawn = draw(), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = Look.context.createCGImage(drawn, from: drawn.extent, format: .RGBA8, colorSpace: space) else {
            return nil
        }
        let image = CIImage(cgImage: bitmap)
        Self.cache[self] = image
        return image
    }

    private func draw() -> CIImage? {
        let rect = CGRect(origin: .zero, size: Self.size)
        switch self {
        case .schoolPhoto:
            // The mottled canvas from school portraits: blotchy teal-gray, lit behind you.
            return Self.mottled(dark: CIColor(red: 0.07, green: 0.13, blue: 0.2),
                                light: CIColor(red: 0.3, green: 0.45, blue: 0.55), rect: rect)
        case .pinkStudio:
            return Self.mottled(dark: CIColor(red: 0.5, green: 0.16, blue: 0.3),
                                light: CIColor(red: 0.9, green: 0.52, blue: 0.66), rect: rect)
        case .laser:
            return Self.laserBackground(rect)
        case .sky:
            return Self.skyBackground(rect)
        case .yourPhoto:
            return nil
        }
    }

    // MARK: - Drawing

    private static func mottled(dark: CIColor, light: CIColor, rect: CGRect) -> CIImage? {
        // Coarse noise, blown up and blurred into soft blotches.
        guard let random = CIFilter.randomGenerator().outputImage else { return nil }
        // The generator's alpha is random too; make the noise solid.
        let tile = CGRect(x: 0, y: 0, width: rect.width / 40 + 8, height: rect.height / 40 + 8)
        let blotches = random.cropped(to: tile).settingAlphaOne(in: tile).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 40, y: 40))
            .applyingGaussianBlur(sigma: 70)
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 4])
            .applyingFilter("CIColorClamp")
        let colored = blotches.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": dark, "inputColor1": light,
        ])
        // A soft light spot behind the person, darker corners.
        let spot = CIFilter.radialGradient()
        spot.center = CGPoint(x: rect.midX, y: rect.height * 0.55)
        spot.radius0 = 0
        spot.radius1 = Float(rect.width * 0.8)
        spot.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.18)
        spot.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        var image = colored.cropped(to: rect)
        if let glow = spot.outputImage?.cropped(to: rect) {
            image = glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        return image.applyingFilter("CIVignette", parameters: ["inputIntensity": 0.8, "inputRadius": 1.6])
            .cropped(to: rect)
    }

    /// The 90s school-photo laser background: neon beams on deep blue-purple.
    private static func laserBackground(_ rect: CGRect) -> CIImage? {
        var random = SeededRandom(seed: 90)
        let image = UIGraphicsImageRenderer(size: rect.size, format: rendererFormat).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.04, green: 0.03, blue: 0.2, alpha: 1).cgColor,
                          UIColor(red: 0.2, green: 0.03, blue: 0.3, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
            }
            let beams: [UIColor] = [.cyan, .magenta, UIColor(red: 0.4, green: 0.6, blue: 1, alpha: 1), .white]
            cg.setLineCap(.round)
            for _ in 0..<18 {
                let start = random.edgePoint(in: rect), end = random.edgePoint(in: rect)
                let color = beams[random.next(beams.count)]
                for (width, alpha) in [(70.0, 0.05), (28.0, 0.14), (10.0, 0.45), (4.0, 1.0)] {
                    cg.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
                    cg.setLineWidth(width)
                    cg.move(to: start)
                    cg.addLine(to: end)
                    cg.strokePath()
                }
            }
        }
        return image.cgImage.map { CIImage(cgImage: $0) }
    }

    private static func skyBackground(_ rect: CGRect) -> CIImage? {
        var random = SeededRandom(seed: 7)
        let image = UIGraphicsImageRenderer(size: rect.size, format: rendererFormat).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1).cgColor,
                          UIColor(red: 0.62, green: 0.82, blue: 1, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: rect.maxY), options: [])
            }
            // Puffy clouds: clusters of soft white circles.
            for _ in 0..<7 {
                let center = CGPoint(x: random.unit() * rect.width, y: random.unit() * rect.height * 0.8)
                for _ in 0..<24 {
                    let r = rect.width * (0.03 + random.unit() * 0.06)
                    let c = CGPoint(x: center.x + (random.unit() - 0.5) * rect.width * 0.35,
                                    y: center.y + (random.unit() - 0.5) * rect.width * 0.07)
                    cg.setFillColor(UIColor(white: 1, alpha: 0.3).cgColor)
                    cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r * 0.8, width: r * 2, height: r * 1.6))
                }
            }
        }
        guard let cg = image.cgImage else { return nil }
        let base = CIImage(cgImage: cg)
        return base.clampedToExtent().applyingGaussianBlur(sigma: 28).cropped(to: base.extent)
    }

    private static var rendererFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return format
    }
}

/// Always draws the same "random" backdrop.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1 }

    mutating func unit() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
    }

    mutating func next(_ upperBound: Int) -> Int { min(Int(unit() * CGFloat(upperBound)), upperBound - 1) }

    mutating func edgePoint(in rect: CGRect) -> CGPoint {
        let t = unit()
        switch next(4) {
        case 0: return CGPoint(x: t * rect.width, y: 0)
        case 1: return CGPoint(x: t * rect.width, y: rect.height)
        case 2: return CGPoint(x: 0, y: t * rect.height)
        default: return CGPoint(x: rect.width, y: t * rect.height)
        }
    }
}
