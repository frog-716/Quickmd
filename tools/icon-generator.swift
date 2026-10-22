// Quickmd 图标生成器（三款极客风候选）
// ---------------------------------------------------------------------------
// 用法：
//   swiftc tools/icon-generator.swift -o /tmp/icongen
//   /tmp/icongen <设计号 1|2|3> <画布边长> <输出 png 路径>
//
// 为什么不用 AI 生成：水印不可控，且发光渐变在小尺寸下糊成一团。
// 代码绘制的优势：纯扁平、边缘锐利、任何尺寸都清晰，而且图标可复现。
//
// 设计号：
//   1 = 终端绿：近黑底 + 荧光绿 ">_" 提示符
//   2 = 蓝图靛蓝：深靛蓝底 + 青色刘海轮廓线 + 悬浮光标
//   3 = 像素琥珀：哑黑底 + 琥珀 8-bit 像素 Q + 橙色光标像素
//
// 坐标一律按 1024×1024 设计稿书写，缩放由调用方决定。

import AppKit

// MARK: - 工具

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// macOS 图标网格：1024 画布里，图形占 824×824，圆角 185（系统 squircle 近似值）
let shapeRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shapeRadius: CGFloat = 185

func fillSquircle(_ c: NSColor) {
    let p = NSBezierPath(roundedRect: shapeRect, xRadius: shapeRadius, yRadius: shapeRadius)
    c.setFill()
    p.fill()
}

// MARK: - 三款设计

func drawTerminal() {
    fillSquircle(color(0x0B0B0C))

    let green = color(0x39FF14)
    green.setStroke()

    // ">" 尖括号：终端提示符
    let chevron = NSBezierPath()
    chevron.lineWidth = 78
    chevron.lineJoinStyle = .miter
    chevron.miterLimit = 6
    chevron.move(to: NSPoint(x: 372, y: 286))
    chevron.line(to: NSPoint(x: 556, y: 512))
    chevron.line(to: NSPoint(x: 372, y: 738))
    chevron.stroke()

    // "_" 光标方块
    green.setFill()
    NSBezierPath(rect: NSRect(x: 620, y: 286, width: 176, height: 78)).fill()
}

func drawBlueprint() {
    fillSquircle(color(0x10162B))

    let cyan = color(0x4CC9F0)
    cyan.setStroke()

    // 屏幕轮廓 + 顶部中间的刘海缺口
    let screen = NSBezierPath()
    screen.lineWidth = 9
    screen.lineJoinStyle = .round
    screen.move(to: NSPoint(x: 248, y: 700))
    screen.line(to: NSPoint(x: 452, y: 700))
    screen.line(to: NSPoint(x: 452, y: 652))
    screen.line(to: NSPoint(x: 572, y: 652))
    screen.line(to: NSPoint(x: 572, y: 700))
    screen.line(to: NSPoint(x: 776, y: 700))
    screen.line(to: NSPoint(x: 776, y: 318))
    screen.line(to: NSPoint(x: 248, y: 318))
    screen.close()
    screen.stroke()

    // 悬浮在刘海下方的光标块
    cyan.setFill()
    NSBezierPath(rect: NSRect(x: 478, y: 430, width: 68, height: 68)).fill()
}

func drawPixel() {
    fillSquircle(color(0x0A0A0A))

    let amber = color(0xFFB000)
    let orange = color(0xFF6B00)

    // 8-bit 像素 Q：6 列 × 7 行，行序自下而上。
    // 橙色两格是 Q 的斜尾巴，落在右下角，同时兼任「光标」意象。
    let cell: CGFloat = 106
    let cols = 6, rows = 7
    let ox: CGFloat = 512 - CGFloat(cols) * cell / 2
    let oy: CGFloat = 512 - CGFloat(rows) * cell / 2

    // 'A' = 琥珀像素，'T' = 橙色尾巴像素，'.' = 空
    let grid: [[Character]] = [
        [".", "A", "A", "A", "T", "."],
        ["A", ".", ".", ".", "A", "T"],
        ["A", ".", ".", ".", "A", "."],
        ["A", ".", ".", ".", "A", "."],
        ["A", ".", ".", ".", "A", "."],
        ["A", ".", ".", ".", "A", "."],
        [".", "A", "A", "A", ".", "."]
    ]

    for (row, line) in grid.enumerated() {
        for (col, ch) in line.enumerated() where ch != "." {
            (ch == "T" ? orange : amber).setFill()
            NSBezierPath(rect: NSRect(x: ox + CGFloat(col) * cell,
                                      y: oy + CGFloat(row) * cell,
                                      width: cell, height: cell)).fill()
        }
    }
}

// MARK: - 入口

let args = CommandLine.arguments
guard args.count >= 4, let design = Int(args[1]), let side = Int(args[2]) else {
    FileHandle.standardError.write("用法: icongen <1|2|3> <边长> <输出路径>\n".data(using: .utf8)!)
    exit(2)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: side, pixelsHigh: side,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    exit(3)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// 把 1024 设计稿缩放到目标尺寸
let scale = CGFloat(side) / 1024.0
let transform = NSAffineTransform()
transform.scale(by: scale)
transform.concat()

switch design {
case 1: drawTerminal()
case 2: drawBlueprint()
case 3: drawPixel()
default: exit(2)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
try png.write(to: URL(fileURLWithPath: args[3]))
