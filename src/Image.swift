// JPEG documents (required by IPP Everywhere) and printer icons, using macOS ImageIO + CoreGraphics.
import CoreGraphics
import Foundation
import ImageIO

/// Renders a JPEG (or any ImageIO-readable image) at the printer's full width (1680 dots = 210 mm)
/// into an uncompressed CUPS raster file ("RaS3", 8-bit sGray, 203 dpi), so the normal raster path prints it.
/// Images are scaled to fit 1680 x 8000 dots (about 1 m of paper at most); very tall ones get narrower.
func convertImageToRaster(_ input: URL, _ output: URL) throws {
    guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw RasterError("not a readable image") }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    var pw = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    var ph = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    if orientation >= 5 { swap(&pw, &ph) }            // EXIF orientations 5-8 are rotated by 90°
    guard pw > 0, ph > 0 else { throw RasterError("image has no size") }
    let width = ESCPOS.dots
    let scale = min(Double(width) / Double(pw), Double(Limits.maxImageRows) / Double(ph))
    let drawW = max(1, min(width, Int((Double(pw) * scale).rounded())))
    let height = max(1, min(Limits.maxImageRows, Int((Double(ph) * scale).rounded())))
    // The thumbnail API applies the EXIF orientation and scales in one step.
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: max(drawW, height)]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw RasterError("cannot decode image") }
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let pixelsRaw = ctx.data else { throw RasterError("cannot allocate \(width)x\(height) bitmap") }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: (width - drawW) / 2, y: 0, width: drawW, height: height))   // centered

    var header = [UInt8](repeating: 0, count: 1796)
    func put(_ off: Int, _ v: Int) {
        let u = UInt32(v)
        header[off] = UInt8(u >> 24); header[off + 1] = UInt8((u >> 16) & 0xFF)
        header[off + 2] = UInt8((u >> 8) & 0xFF); header[off + 3] = UInt8(u & 0xFF)
    }
    put(276, 203); put(280, 203)                                   // HWResolution
    put(352, width * 72 / 203); put(356, height * 72 / 203)        // PageSize in points
    put(372, width); put(376, height)                              // cupsWidth, cupsHeight
    put(384, 8); put(388, 8); put(392, width)                      // bits per color/pixel, bytes per line
    put(400, 18)                                                   // cupsColorSpace = sGray
    makePrivateFile(output)
    guard let fh = FileHandle(forWritingAtPath: output.path) else { throw RasterError("cannot write \(output.path)") }
    defer { try? fh.close() }
    fh.write(Data("RaS3".utf8) + Data(header))
    // CGContext rows are top-down in memory for a bitmap context like this one.
    fh.write(Data(bytes: pixelsRaw, count: width * height))
}

/// PNG printer icons (48, 128 and 512 px) drawn at startup: a printer with paper coming out.
func makePrinterIcon(size: Int) -> Data {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s),
               cornerWidth: r * s, cornerHeight: r * s, transform: nil)
    }
    // paper sheet (top), printer body, output slot, status light
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.setStrokeColor(red: 0.55, green: 0.57, blue: 0.6, alpha: 1)
    ctx.setLineWidth(max(1, s * 0.015))
    ctx.addPath(rr(0.24, 0.45, 0.52, 0.47, 0.02)); ctx.drawPath(using: .fillStroke)
    ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 1)
    for i in 0..<4 { ctx.fill(CGRect(x: 0.31 * s, y: (0.80 - CGFloat(i) * 0.08) * s, width: (i == 3 ? 0.22 : 0.38) * s, height: 0.025 * s)) }
    ctx.setFillColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1)
    ctx.addPath(rr(0.08, 0.10, 0.84, 0.40, 0.08)); ctx.fillPath()
    ctx.setFillColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    ctx.fill(CGRect(x: 0.2 * s, y: 0.43 * s, width: 0.6 * s, height: 0.03 * s))
    ctx.setFillColor(red: 0.2, green: 0.55, blue: 1.0, alpha: 1)
    ctx.fillEllipse(in: CGRect(x: 0.76 * s, y: 0.2 * s, width: 0.07 * s, height: 0.07 * s))
    guard let img = ctx.makeImage() else { return Data() }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// Sniffs a document's real format (for document-format application/octet-stream).
func sniffFormat(_ url: URL) -> String? {
    guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
    defer { try? fh.close() }
    let head = [UInt8](fh.readData(ofLength: 8))
    if head.starts(with: Array("RaS2".utf8)) { return "image/pwg-raster" }
    if head == Array("UNIRAST".utf8) + [0] { return "image/urf" }
    if head.count >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF { return "image/jpeg" }
    return nil
}
