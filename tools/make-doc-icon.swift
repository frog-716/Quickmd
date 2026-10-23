// 由 assets/icons/source-reference.jpg 生成 Quickmd.icns
//
// 目标：做出来的图标和原图里的样子**完全一致**（白色圆角方块 + 纸卷 + 笔）。
//
// 做法：
//  1. 探测原图里那个「白色圆角方块」（应用图标本体）的精确左右边界
//     —— 用那条深色描边（亮度约 206-214）当边界，不能用外圈的柔光阴影
//  2. 原图里方块是居中的正方形，上下边界按左右边界推算
//  3. 把**整张图**等比缩放，使方块正好落在 macOS 规范的 824x824 区域内
//  4. 用与原图比例一致的圆角遮罩把方块外变透明，输出全套尺寸 -> iconutil
//
// 关键教训：不能把方块直接"裁"出来——方块外圈有一层柔光阴影，
// 裁断会在图标里留下一道生硬的方形接缝；必须整图缩放再遮罩。
import CoreGraphics
import ImageIO
import Foundation

let root = "/Users/frog/Projects/Quick-md"
let srcPath = "\(root)/assets/icons/source-reference.jpg"
let outDir = "\(root)/assets/icons/Quickmd.iconset"
let previewPath = "/tmp/quickmd-icon-preview.png"

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("读取源图失败"); exit(1)
}
let W = img.width, H = img.height
let cs = CGColorSpaceCreateDeviceRGB()

// ---------- 1. 探测方块边界 ----------
var buf = [UInt8](repeating: 0, count: W * H * 4)
let probe = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                       space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
probe.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

func lum(_ x: Int, _ y: Int) -> Double {
    let i = (y * W + x) * 4
    return (Double(buf[i]) + Double(buf[i+1]) + Double(buf[i+2])) / 3
}

// 页面底色约 253；方块外圈的柔光阴影是 232~252 的缓变；
// 真正的硬边是那条深色描边（< 225）。阈值取 225 正好只咬住描边。
func edge(from: Int, to: Int, step: Int, fixed: Int, horizontal: Bool) -> Int {
    var v = from
    while v != to {
        let cur = horizontal ? lum(v, fixed) : lum(fixed, v)
        if cur < 225 { return v }
        v += step
    }
    return from
}

let midY = H / 2
let boxLeft = edge(from: 0, to: W, step: 1, fixed: midY, horizontal: true)
let boxRight = edge(from: W - 1, to: 0, step: -1, fixed: midY, horizontal: true)
// 上下边界按「居中正方形」推算：
// 左右探测出的中心 (boxLeft+boxRight)/2 与图像中心一致，顶部柔光起点也和左边缘对得上，
// 所以直接用左右边界当上下边界最稳（单独探测底边会先撞到纸卷投影或柔光渐变）。
let boxTop = boxLeft
let boxBottom = boxRight
let boxW = CGFloat(boxRight - boxLeft)
print("方块边界 x=\(boxLeft)..\(boxRight)  y=\(boxTop)..\(boxBottom)  边长 \(Int(boxW))")

// ---------- 2. 整图缩放，方块对齐到 824 规范区 ----------
let canvas = 1024
let spec = CGRect(x: 100, y: 100, width: 824, height: 824)   // macOS 图标规范
let scale = spec.width / boxW
let drawW = CGFloat(W) * scale
let drawH = CGFloat(H) * scale
// 源图显示坐标 -> 画布坐标：显示左边贴 spec.minX，显示底边贴 spec.minY
let drawX = spec.minX - CGFloat(boxLeft) * scale
let drawY = spec.minY - CGFloat(H - 1 - boxBottom) * scale

guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// 圆角遮罩：185/824 ≈ 22.4%，与原图圆角比例一致
ctx.addPath(CGPath(roundedRect: spec, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(img, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
let full = ctx.makeImage()!

// ---------- 3. 输出 iconset ----------
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
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
if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: previewPath) as CFURL,
                                              "public.png" as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, full, nil)
    CGImageDestinationFinalize(dest)
}
print("iconset 完成 -> \(outDir)")
