import AppKit

/// 画像の変換（PNG化・縮小）
enum ImageUtil {
    static func pngData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// 長い辺が maxSide 以下になるように縮小した JPEG。
    /// keepColorSpace が true なら、元の色空間（Display P3 など）のまま保存する（色が変わらないように）
    static func jpegData(_ image: NSImage, maxSide: CGFloat, quality: CGFloat, keepColorSpace: Bool = false) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        var ctx: CGContext?
        if keepColorSpace, let source = cg.colorSpace, source.model == .rgb { ctx = context(source) }
        guard let ctx = ctx ?? context(CGColorSpaceCreateDeviceRGB()) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))  // 透明な部分は白にする（JPEG は透明を持てない）
        ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// 長い辺が maxSide 以下になるように縮小した PNG
    static func thumbnail(_ image: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    static func pixelSize(_ image: NSImage) -> (Int, Int) {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return (cg.width, cg.height) }
        return (Int(image.size.width), Int(image.size.height))
    }
}
