import CoreImage
import UIKit

/// Photo booth strips and collages, built from several shots.
enum Collage {
    private static let paper = CIColor(red: 0.98, green: 0.98, blue: 0.97)

    /// The shape of each shot: square for the booth; for collages, stacked 3:2 halves (2 shots)
    /// or a 2×2 grid of 3:4 tiles (4 shots). The whole collage is 3:4.
    static func cellAspect(forCollageOf count: Int) -> CGFloat {
        let size = collageCells(count: count)[0].size
        return size.width / size.height
    }

    private static let collageSize = CGSize(width: 1800, height: 2400)
    private static let gutter: CGFloat = 16

    /// Tile rectangles, first shot at the top-left (Core Image's y axis points up).
    private static func collageCells(count: Int) -> [CGRect] {
        let W = collageSize.width, H = collageSize.height, g = gutter
        if count == 2 {
            let h = (H - 3 * g) / 2
            return [CGRect(x: g, y: g * 2 + h, width: W - 2 * g, height: h),
                    CGRect(x: g, y: g, width: W - 2 * g, height: h)]
        }
        let w = (W - 3 * g) / 2, h = (H - 3 * g) / 2
        return [CGRect(x: g, y: g * 2 + h, width: w, height: h),
                CGRect(x: g * 2 + w, y: g * 2 + h, width: w, height: h),
                CGRect(x: g, y: g, width: w, height: h),
                CGRect(x: g * 2 + w, y: g, width: w, height: h)]
    }

    /// A collage of 2 or 4 shots with thin white gutters. The date stamp goes on the last tile.
    static func grid(_ shots: [CIImage], look: Look, stamp: Date?) -> CIImage {
        let cells = collageCells(count: shots.count)
        var canvas = CIImage(color: paper).cropped(to: CGRect(origin: .zero, size: collageSize))
        for (index, (shot, cell)) in zip(shots, cells).enumerated() {
            let tile = look.apply(to: shot.filling(CGRect(origin: .zero, size: cell.size)),
                                  stamp: index == shots.count - 1 ? stamp : nil)
            canvas = tile.transformed(by: CGAffineTransform(translationX: cell.minX, y: cell.minY))
                .composited(over: canvas)
        }
        return canvas
    }

    /// A classic 4-shot photo booth strip, with the date printed at the bottom.
    static func photoBooth(_ shots: [CIImage], look: Look, date: Date?) -> CIImage {
        let cell: CGFloat = 900, border: CGFloat = 60, gap: CGFloat = 40, footer: CGFloat = 240
        let width = cell + border * 2
        let height = border + CGFloat(shots.count) * cell + CGFloat(shots.count - 1) * gap + footer
        var canvas = CIImage(color: paper).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        for (index, shot) in shots.enumerated() {
            let y = height - border - CGFloat(index + 1) * cell - CGFloat(index) * gap
            let tile = look.apply(to: shot.filling(CGRect(x: 0, y: 0, width: cell, height: cell)))
            canvas = tile.transformed(by: CGAffineTransform(translationX: border, y: y)).composited(over: canvas)
        }
        if let date {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            let font = UIFont(name: "AmericanTypewriter", size: 64) ?? .systemFont(ofSize: 64)
            let label = Look.text(formatter.string(from: date).uppercased(), font: font,
                                  color: UIColor(white: 0.25, alpha: 1))
            canvas = label.transformed(by: CGAffineTransform(translationX: (width - label.extent.width) / 2,
                                                             y: (footer - label.extent.height) / 2 + 10))
                .composited(over: canvas)
        }
        return canvas
    }
}
