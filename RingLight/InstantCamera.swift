import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// How you saw yourself on an old instant camera: never the actual photo.
enum OldLens {
    /// The small flat mirror next to the lens, for aiming selfies.
    case selfieMirror
    /// The tiny window on the back.
    case viewfinder

    func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        switch self {
        case .selfieMirror:
            // A little soft and silvery, darker toward the rim.
            return image.clampedToExtent()
                .applyingGaussianBlur(sigma: extent.width / 320)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.84, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.88, w: 0),
                    "inputBiasVector": CIVector(x: 0.07, y: 0.07, z: 0.08, w: 0),
                ])
                .applyingFilter("CIVignette", parameters: ["inputIntensity": 0.9, "inputRadius": 1.2])
                .cropped(to: extent)

        case .viewfinder:
            // The viewfinder sits above the lens, so it sees a slightly different framing
            // (parallax). It's also dim, a little curved, and soft in the corners.
            let offset = CGAffineTransform(translationX: center.x - extent.width * 0.04, y: center.y + extent.height * 0.05)
                .scaledBy(x: 1.12, y: 1.12)
                .translatedBy(x: -center.x, y: -center.y)
            let bump = CIFilter.bumpDistortion()
            bump.inputImage = image.clampedToExtent().transformed(by: offset)
            bump.center = center
            bump.radius = Float(extent.width * 0.85)
            bump.scale = 0.22
            return (bump.outputImage ?? image)
                .applyingGaussianBlur(sigma: extent.width / 360)
                .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -0.5])
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.85])
                .applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -0.01, y: 0.012, z: 0, w: 0)])
                .applyingFilter("CIVignette", parameters: ["inputIntensity": 1.3, "inputRadius": 1.3])
                .cropped(to: extent)
        }
    }
}

/// SHAKE mode's camera: an instant camera. From the front you aim with the selfie mirror;
/// from the back you look through the viewfinder. Prints come out of the slot on top.
struct InstantCamera: View {
    let isFront: Bool
    let source: () -> CIImage?
    /// Goes up with every shot, to fire the flash.
    let shotCount: Int
    /// A fresh print is coming out of the slot.
    let ejecting: Bool
    var onEjected: () -> Void

    @State private var flash = false
    @State private var ejected: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                CameraShell(width: w)
                PrintSlot(width: w * 0.5).position(x: w / 2, y: w * 0.03)
                if isFront { front(w: w, h: h) } else { back(w: w, h: h) }
                Wordmark(size: w * 0.034).position(x: w / 2, y: h - w * 0.075)
            }
            .overlay(alignment: .top) { ejectingPrint(w: w) }
        }
        .onChange(of: shotCount) { _, _ in fireFlash() }
        .onChange(of: ejecting) { _, ejecting in if ejecting { eject() } }
        .onAppear { if ejecting { eject() } }
    }

    // MARK: - Front: viewfinder window, flash, lens, selfie mirror

    private func front(w: CGFloat, h: CGFloat) -> some View {
        let lens = w * 0.6
        let lensCenter = CGPoint(x: w / 2, y: h * 0.57)
        let mirror = w * 0.15
        return ZStack {
            Window(cornerRadius: w * 0.018)
                .frame(width: w * 0.14, height: w * 0.105)
                .position(x: w * 0.18, y: h * 0.15)
            LightSensor()
                .frame(width: w * 0.035, height: w * 0.035)
                .position(x: w * 0.53, y: h * 0.15)
            FlashWindow(firing: flash, cornerRadius: w * 0.022)
                .frame(width: w * 0.3, height: w * 0.12)
                .position(x: w * 0.76, y: h * 0.15)
            LensBarrel()
                .frame(width: lens, height: lens)
                .position(lensCenter)
            // Set into the lens housing at the top right, like on a real instant camera.
            SelfieMirror(source: source, cornerRadius: mirror * 0.24)
                .frame(width: mirror, height: mirror)
                .position(x: lensCenter.x + lens * 0.37, y: lensCenter.y - lens * 0.37)
        }
    }

    // MARK: - Back: film door and viewfinder

    private func back(w: CGFloat, h: CGFloat) -> some View {
        let window = CGSize(width: w * 0.42, height: w * 0.42 * 4 / 3)
        return ZStack {
            // The film door: a fine seam, with its latch on the side.
            RoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 1)
                .overlay(RoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1).offset(y: 1))
                .frame(width: w * 0.84, height: h * 0.72)
                .position(x: w / 2, y: h * 0.5)
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.018, height: h * 0.12)
                .position(x: w * 0.93, y: h * 0.5)

            Eyepiece(source: source, window: window)
                .position(x: w / 2, y: h * 0.45)

            HStack(spacing: w * 0.02) {
                Circle().fill(Color(red: 0.35, green: 0.85, blue: 0.45))
                    .shadow(color: Color(red: 0.35, green: 0.85, blue: 0.45).opacity(0.8), radius: 3)
                Circle().fill(Color(white: 0.35))
            }
            .frame(width: w * 0.06, height: w * 0.022)
            .position(x: w * 0.82, y: h * 0.1)
        }
    }

    // MARK: - Flash and the print coming out

    private func fireFlash() {
        guard isFront else { return }
        withAnimation(.easeIn(duration: 0.04)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.5)) { flash = false }
        }
    }

    /// A blank print rising out of the slot, clipped so it looks like it comes from inside.
    private func ejectingPrint(w: CGFloat) -> some View {
        let cardWidth = w * 0.42
        let cardHeight = cardWidth * 1.58
        return PrintCard(image: nil, progress: 0, width: cardWidth)
            .offset(y: cardHeight - ejected * cardHeight * 0.8)
            .frame(width: w, height: cardHeight, alignment: .top)
            .clipped()
            .offset(y: -cardHeight + w * 0.03)
            .opacity(ejecting ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func eject() {
        ejected = 0
        // The motor whirr.
        let motor = UIImpactFeedbackGenerator(style: .light)
        for tick in 0..<22 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(tick) * 0.05) { motor.impactOccurred(intensity: 0.7) }
        }
        withAnimation(.linear(duration: 1.1).delay(0.2)) { ejected = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onEjected() }
    }
}

// MARK: - Materials

private enum Palette {
    static let chalk = Color(red: 0.935, green: 0.925, blue: 0.9)
    static let chalkShade = Color(red: 0.86, green: 0.845, blue: 0.815)
    static let graphite = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let graphiteLight = Color(red: 0.3, green: 0.3, blue: 0.31)
}

/// Fine grain so the plastic reads as matte, not flat color. Drawn once.
private let grainImage: UIImage? = {
    let size = CGSize(width: 256, height: 256)
    guard let noise = CIFilter.randomGenerator().outputImage?
            .cropped(to: CGRect(origin: .zero, size: size))
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0]),
          let cg = CIContext().createCGImage(noise, from: CGRect(origin: .zero, size: size)) else { return nil }
    return UIImage(cgImage: cg)
}()

/// The matte camera body: soft top light, a crisp highlight along the top edge, grounded shadow.
private struct CameraShell: View {
    let width: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Palette.chalk, Palette.chalkShade], startPoint: .top, endPoint: .bottom))
            .overlay {
                if let grainImage {
                    Image(uiImage: grainImage).resizable(resizingMode: .tile)
                        .opacity(0.05)
                        .blendMode(.multiply)
                        .clipShape(shape)
                }
            }
            .overlay(shape.fill(RadialGradient(colors: [.white.opacity(0.45), .clear], center: UnitPoint(x: 0.25, y: 0.05),
                                               startRadius: 0, endRadius: width * 0.9)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0), .black.opacity(0.12)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.22), radius: 22, y: 14)
    }
}

/// The dark slot on top where prints come out.
private struct PrintSlot: View {
    let width: CGFloat

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(white: 0.05), Color(white: 0.22)], startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: 6)
            .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 0.75).offset(y: 1.5).mask(Capsule().offset(y: 2)))
    }
}

/// A recessed glass window with a graphite bezel.
private struct Window: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.graphite)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius * 0.7, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.3), Color(white: 0.03)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .topLeading, endPoint: .center)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.7, style: .continuous)))
                    .padding(3)
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
    }
}

/// The little light-meter eye.
private struct LightSensor: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 0.25, green: 0.22, blue: 0.3), .black], center: .init(x: 0.35, y: 0.35),
                                 startRadius: 0, endRadius: 10))
            .overlay(Circle().strokeBorder(Palette.graphiteLight, lineWidth: 1.5))
    }
}

/// Fresnel flash window: fine vertical ridges that light up when it fires.
private struct FlashWindow: View {
    let firing: Bool
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.graphite)
            .overlay(
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(firing ? .white : Color(white: 0.9)))
                    guard !firing else { return }
                    var x: CGFloat = 0
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: 1.2, height: size.height)), with: .color(.black.opacity(0.1)))
                        context.fill(Path(CGRect(x: x + 1.2, y: 0, width: 0.8, height: size.height)), with: .color(.white.opacity(0.8)))
                        x += 3.2
                    }
                }
                .overlay(LinearGradient(colors: [.white.opacity(0.5), .clear, .black.opacity(0.08)],
                                        startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.6, style: .continuous))
                .padding(3.5)
            )
            .shadow(color: .white.opacity(firing ? 1 : 0), radius: firing ? 50 : 0)
            .shadow(color: .white.opacity(firing ? 0.9 : 0), radius: firing ? 20 : 0)
    }
}

/// The lens: graphite housing, a knurled focus grip, engraved markings, and coated glass.
private struct LensBarrel: View {
    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                // Housing, lit from the top.
                Circle().fill(LinearGradient(colors: [Palette.graphiteLight, Palette.graphite, Color(white: 0.1)],
                                             startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 1)

                // Knurled grip ring.
                Canvas { context, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let outer = size.width / 2 * 0.93, inner = size.width / 2 * 0.8
                    for i in 0..<180 {
                        let angle = Double(i) / 180 * 2 * .pi
                        var ridge = Path()
                        ridge.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
                        ridge.addLine(to: CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
                        context.stroke(ridge, with: .color(i.isMultiple(of: 2) ? .black.opacity(0.45) : .white.opacity(0.12)),
                                       lineWidth: 1)
                    }
                }

                // Inner bezel with engraved lens markings.
                Circle().fill(Color(white: 0.06)).padding(d * 0.1)
                EngravedRing(text: "RING LIGHT  INSTANT LENS  60mm  1:12.7  ", radius: d * 0.335, fontSize: d * 0.035)

                // Coated glass.
                ZStack {
                    Circle().fill(RadialGradient(colors: [Color(red: 0.1, green: 0.12, blue: 0.2), Color(red: 0.02, green: 0.02, blue: 0.05)],
                                                 center: .center, startRadius: 0, endRadius: d * 0.26))
                    Circle().fill(AngularGradient(colors: [.clear, Color(red: 0.55, green: 0.3, blue: 0.85).opacity(0.35), .clear,
                                                           Color(red: 0.3, green: 0.8, blue: 0.55).opacity(0.25), .clear],
                                                  center: .center))
                        .blur(radius: 6)
                    Circle().fill(.white.opacity(0.85)).frame(width: d * 0.07, height: d * 0.05)
                        .blur(radius: 1.5).offset(x: -d * 0.09, y: -d * 0.1)
                    Circle().fill(.white.opacity(0.4)).frame(width: d * 0.025).blur(radius: 0.5).offset(x: d * 0.1, y: d * 0.09)
                }
                .clipShape(Circle())
                .padding(d * 0.24)
                .overlay(Circle().strokeBorder(Color(white: 0.25), lineWidth: 1.5).padding(d * 0.24))
            }
        }
    }
}

/// Small white lettering around the inside of the lens.
private struct EngravedRing: View {
    let text: String
    let radius: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let characters = Array(text)
            for (index, character) in characters.enumerated() {
                let angle = Double(index) / Double(characters.count) * 2 * .pi - .pi / 2
                var glyph = context
                glyph.translateBy(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
                glyph.rotate(by: .radians(angle + .pi / 2))
                glyph.draw(Text(String(character))
                            .font(.system(size: fontSize, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65)),
                           at: .zero)
            }
        }
    }
}

/// The flat selfie mirror, with your live reflection.
private struct SelfieMirror: View {
    let source: () -> CIImage?
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        CameraPreview(source: source, look: .normal, dateStamp: false, lens: .selfieMirror)
            .clipShape(shape)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.3), .clear, .white.opacity(0.08)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)))
            // Thin chrome edge inside a graphite bezel.
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.45)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .padding(3)
            .background(RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous).fill(Palette.graphite))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
    }
}

/// The viewfinder eyepiece: ribbed rubber eyecup around a dim window with frame lines.
private struct Eyepiece: View {
    let source: () -> CIImage?
    let window: CGSize

    var body: some View {
        let cup = RoundedRectangle(cornerRadius: window.width * 0.16, style: .continuous)
        ZStack {
            cup.fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .overlay(cup.strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
                .frame(width: window.width + 40, height: window.height + 40)
            cup.fill(Color.black)
                .frame(width: window.width + 12, height: window.height + 12)
            CameraPreview(source: source, look: .normal, dateStamp: false, lens: .viewfinder)
                .frame(width: window.width, height: window.height)
                .clipShape(RoundedRectangle(cornerRadius: window.width * 0.08, style: .continuous))
                .overlay(FrameLines().padding(window.width * 0.07))
        }
    }
}

/// The bright corner marks you frame the shot with.
private struct FrameLines: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) * 0.12
            Path { path in
                let r = CGRect(origin: .zero, size: geo.size)
                for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                         (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                    path.move(to: CGPoint(x: corner.x + dx * s, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * s))
                }
            }
            .stroke(.white.opacity(0.75), lineWidth: 1.5)
        }
    }
}

/// Small, widely spaced lettering pressed into the plastic.
private struct Wordmark: View {
    let size: CGFloat

    var body: some View {
        Text("RING LIGHT")
            .font(.system(size: size, weight: .semibold))
            .tracking(size * 0.35)
            .foregroundStyle(Palette.chalkShade.opacity(0.9))
            .shadow(color: .white.opacity(0.9), radius: 0, y: 1)
            .shadow(color: .black.opacity(0.25), radius: 0, y: -0.5)
    }
}
