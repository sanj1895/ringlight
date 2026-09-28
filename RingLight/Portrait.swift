import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// What happens behind the person.
enum BackgroundEffect {
    /// Portrait mode.
    case blur
    /// Backdrop mode.
    case replace(CIImage)

    func apply(to image: CIImage, mask: CIImage) -> CIImage {
        switch self {
        case .blur: PersonSegmenter.blurBackground(image, mask: mask)
        case .replace(let backdrop): PersonSegmenter.replaceBackground(image, mask: mask, with: backdrop)
        }
    }
}

/// Portrait and backdrop modes: finds the person with Vision, then blurs or swaps
/// everything behind them. Works on either camera, live in the preview and on the saved photo.
final class PersonSegmenter {
    private let request = VNGeneratePersonSegmentationRequest()

    init(quality: VNGeneratePersonSegmentationRequest.QualityLevel) {
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// A mask the size of `image`: white where the person is.
    func mask(for image: CIImage) -> CIImage? {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        return mask
            .transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width,
                                               y: image.extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
    }

    static func blurBackground(_ image: CIImage, mask: CIImage) -> CIImage {
        let radius = max(image.extent.width, image.extent.height) / 90
        let background = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
        return put(image, over: background, mask: mask)
    }

    static func replaceBackground(_ image: CIImage, mask: CIImage, with backdrop: CIImage) -> CIImage {
        put(image, over: backdrop.filling(image.extent), mask: mask)
    }

    private static func put(_ image: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }
}
