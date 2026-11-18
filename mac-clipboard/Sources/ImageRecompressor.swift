import AppKit

/// 古い画像（PNG）を、軽い JPEG にする。見た目が変わるので、変えないほうがよいものは触らない。
enum ImageRecompressor {
    /// JPEG にできて、十分に軽くなるときだけ、その JPEG を返す。次のときは nil（そのまま PNG で残す）:
    /// - PNG ではない／読めない
    /// - 透明な部分がある（JPEG は透明を持てない）
    /// - 大きすぎる（メモリのため）
    /// - JPEG にしても、あまり小さくならない（単色の図など。minSaving が 0.3 なら 3 割以上軽くなるときだけ）
    static func jpegIfWorthwhile(_ png: Data, quality: CGFloat = 0.88, minSaving: Double = 0.3) -> Data? {
        guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]),
              let image = NSImage(data: png),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width * cg.height <= 40_000_000 else { return nil }
        if hasTransparency(cg) { return nil }
        guard let jpeg = ImageUtil.jpegData(image, maxSide: .greatestFiniteMagnitude, quality: quality, keepColorSpace: true),
              StoragePolicy.worthwhile(original: png.count, compressed: jpeg.count, minSaving: minSaving) else { return nil }
        return jpeg
    }

    /// 1 画素でも、完全には不透明でないところがあるか
    static func hasTransparency(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return true }  // 調べられないときは、触らない
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var i = 3
        let end = w * h * 4
        while i < end {
            if bytes[i] != 255 { return true }
            i += 4
        }
        return false
    }
}
