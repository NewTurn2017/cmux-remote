import UIKit

/// Draws the demo relay's browser screenshot in code, so no image file ships in the repository.
enum DemoBrowserCapture {
    static let width = 1200
    static let height = 1500
    /// The pretend size of cmux's original screenshot before the relay downscaled it.
    static let sourceWidth = 2400
    static let sourceHeight = 3000

    static func jpegData(captureNumber: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            fill(cg, CGRect(origin: .zero, size: size), white: 0.97)
            fill(cg, CGRect(x: 0, y: 0, width: size.width, height: 120), white: 0.12)
            draw("localhost:3000", at: CGPoint(x: 60, y: 38), size: 36, white: 0.85, weight: .medium)
            draw("cmux Remote demo", at: CGPoint(x: 60, y: 200), size: 84, white: 0.1, weight: .bold)
            draw("Capture #\(captureNumber)", at: CGPoint(x: 60, y: 320), size: 48, white: 0.35, weight: .regular)
            for row in 0..<9 {
                let y = 460 + CGFloat(row) * 110
                let width = row.isMultiple(of: 3) ? size.width - 120 : size.width - 120 - CGFloat(row % 3) * 180
                fill(cg, CGRect(x: 60, y: y, width: width, height: 56), white: 0.86)
            }
        }
        return image.jpegData(compressionQuality: 0.7) ?? Data()
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, white: CGFloat) {
        context.setFillColor(UIColor(white: white, alpha: 1).cgColor)
        context.fill(rect)
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, white: CGFloat, weight: UIFont.Weight) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: UIColor(white: white, alpha: 1),
        ])
    }
}
