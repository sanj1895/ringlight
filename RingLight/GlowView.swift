import SwiftUI
import MetalKit

/// The ring light, built the way Snapchat's is (from Snap's Camera Kit reference UI):
/// - solid light everywhere outside the camera preview,
/// - a rounded glow around the inside of the preview: solid at the very edge, fading
///   fast to 10% strength halfway in, then to nothing. `intensity` makes it thicker.
/// It's drawn as HDR (extended dynamic range) content, so the iPhone can light it
/// brighter than ordinary white.
struct GlowView: UIViewRepresentable {
    var color: Color
    /// 0...1, like Snap's slider. 0 = thin ring, 1 = the glow reaches the middle.
    var intensity: Double
    /// Shape of the camera preview (width / height), see `PreviewLayout`.
    var aspect: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 15  // just enough to follow the screen's HDR headroom
        if let layer = view.layer as? CAMetalLayer {
            layer.isOpaque = false
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }
        context.coordinator.setUp(device: view.device, pixelFormat: view.colorPixelFormat)
        view.delegate = context.coordinator
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.color = color
        context.coordinator.intensity = Float(min(max(intensity, 0), 1))
        context.coordinator.aspect = aspect
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var color: Color = .white {
            didSet {
                var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                linear = SIMD3(Self.toLinear(r), Self.toLinear(g), Self.toLinear(b))
            }
        }
        var intensity: Float = 0.2
        var aspect: CGFloat = 3.0 / 4.0

        private var linear = SIMD3<Float>(1, 1, 1)
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?

        private struct Uniforms {
            var color: SIMD4<Float>   // .w = HDR boost
            var preview: SIMD4<Float> // minX, minY, maxX, maxY in pixels
            var band: Float           // thickness of the glow
        }

        func setUp(device: MTLDevice?, pixelFormat: MTLPixelFormat) {
            guard let device,
                  let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "glowVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "glowFragment")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            queue = device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let buffer = queue?.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

            // How far past normal white the screen can go right now (1.0 = no HDR boost).
            let headroom = Float(view.window?.windowScene?.screen.currentEDRHeadroom ?? 1)
            let scale = Float(view.contentScaleFactor)
            // Same spot ContentView puts the preview in (it's laid out inside the safe area).
            let safe = view.window?.safeAreaInsets ?? .zero
            let safeSize = CGSize(width: view.bounds.width - safe.left - safe.right,
                                  height: view.bounds.height - safe.top - safe.bottom)
            let rect = PreviewLayout.rect(in: safeSize, aspect: aspect).offsetBy(dx: safe.left, dy: safe.top)

            // Snap's sizing: 33pt at intensity 0, up to half the preview width at 1.
            let width = Float(rect.width)
            let maxRadius = (width / 2) / 1.5
            let band = min(width / 2, ((maxRadius - 22) * intensity + 22) * 1.5)

            var uniforms = Uniforms(
                color: SIMD4(linear, max(1, headroom)),
                preview: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY)) * scale,
                band: band * scale)

            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }

        private static func toLinear(_ c: CGFloat) -> Float {
            let c = Float(min(max(c, 0), 1))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct VOut { float4 position [[position]]; };

        struct Uniforms {
            float4 color;
            float4 preview;
            float band;
        };

        // One triangle that covers the whole screen.
        vertex VOut glowVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            VOut out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            return out;
        }

        fragment float4 glowFragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
            float2 p = in.position.xy;
            float3 light = u.color.rgb * u.color.w;

            // Solid light everywhere outside the camera preview.
            if (p.x < u.preview.x || p.y < u.preview.y || p.x > u.preview.z || p.y > u.preview.w) {
                return float4(light, 1.0);
            }

            // Rounded glow around the inside of the preview.
            float2 q = p - u.preview.xy;
            float2 s = u.preview.zw - u.preview.xy;
            float w = u.band;
            float dx = max(max(w - q.x, q.x - (s.x - w)), 0.0);
            float dy = max(max(w - q.y, q.y - (s.y - w)), 0.0);
            float t = length(float2(dx, dy)) / w;   // 0 = inner edge of the glow, 1 = screen edge

            // Snap's gradient: 0 -> 10% at the halfway point -> solid for the outer 10%.
            float a = t < 0.5 ? 0.2 * t
                    : t < 0.9 ? 0.1 + (t - 0.5) * 2.25
                    : 1.0;
            return float4(light * a, a);  // premultiplied
        }
        """
    }
}
