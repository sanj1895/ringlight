import SwiftUI
import MetalKit
import CoreImage

/// Shows the live camera with the current look and date stamp. The view has the same
/// shape as what gets saved, so what you see is exactly what you get.
struct CameraPreview: UIViewRepresentable {
    /// What the camera sees right now (see `CameraModel.frameSource`).
    var source: () -> CIImage?
    var look: Look
    var dateStamp: Bool
    /// SHAKE mode: seen through an old camera's selfie mirror or viewfinder.
    var lens: OldLens?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false  // Core Image draws into the drawable
        view.colorPixelFormat = .bgra8Unorm
        view.backgroundColor = .black
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.source = source
        context.coordinator.look = look
        context.coordinator.dateStamp = dateStamp
        context.coordinator.lens = lens
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var source: () -> CIImage? = { nil }
        var look: Look = .normal
        var dateStamp = false
        var lens: OldLens?

        private lazy var queue = device?.makeCommandQueue()
        private lazy var ciContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let frame = source(),
                  let ciContext,
                  let drawable = view.currentDrawable,
                  let buffer = queue?.makeCommandBuffer() else { return }

            // Fit the frame to the screen first, so the look costs the same at any camera resolution.
            let size = view.drawableSize
            var image = frame.filling(CGRect(origin: .zero, size: size))
            image = look.apply(to: image, stamp: dateStamp ? Date() : nil)
            if let lens { image = lens.apply(to: image) }

            let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                                  pixelFormat: view.colorPixelFormat, commandBuffer: buffer,
                                                  mtlTextureProvider: { drawable.texture })
            destination.colorSpace = colorSpace
            _ = try? ciContext.startTask(toRender: image, to: destination)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
