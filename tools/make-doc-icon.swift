import CoreGraphics
import ImageIO
import Foundation

let srcPath = "/Users/frog/.workbuddy/clipboard-images/clipboard-2026-10-22T12-35-13-764Z-48b47762.jpg"
let outDir = "/tmp/doc-icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("读取失败"); exit(1) }

// 方块边界（探测结果）：x 133–1121，取正方形 y 同尺寸
let bx: CGFloat = 133, bw: CGFloat = 1121 - 133
let by: CGFloat = 1123 - bw   // 与底边对齐的正方形
let cropped = img.cropping(to: CGRect(x: bx, y: by, width: bw, height: bw))!

// 1024 画布，把方块铺满 824 圆角矩形（macOS 规范），裁掉原始圆角
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(cropped, in: bgRect)
let full = ctx.makeImage()!

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    c.interpolationQuality = .high
    c.draw(full, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let out = c.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL,
                                                     "public.png" as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
}
if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/doc-icon-preview.png") as CFURL,
                                              "public.png" as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, full, nil)
    CGImageDestinationFinalize(dest)
}
print("完成")
