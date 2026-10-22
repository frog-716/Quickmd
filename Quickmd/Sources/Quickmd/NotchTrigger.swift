import AppKit

/// 刘海触发器：30Hz 轮询鼠标位置，判断面板该显示还是该收起。
///
/// 为什么是轮询而不是监听全局鼠标事件？
///   全局 mouseMoved 监听需要「辅助功能」授权，系统设置里会多一条 scary 提示。
///   轮询 NSEvent.mouseLocation 只需要读当前鼠标坐标，零授权。
///
/// 职责边界：只回答「该不该显示 / 该不该收起」，不碰面板、文档、菜单。
final class NotchTrigger {
    /// 命中刘海热区 → 显示面板
    var onEnterHotZone: (() -> Void)?
    /// 离开热区与停留区 → 收起面板
    var onLeaveStayRegion: (() -> Void)?
    /// 点击面板后置位；钉住期间鼠标移开也不收起
    var isPinned = false
    /// 面板当前所在矩形（由 AppDelegate 提供），用于判断停留区
    var panelFrameProvider: (() -> NSRect?)?

    private var timer: Timer?

    /// 轮询间隔。30Hz 足够跟手（人手移动远慢于此），且 CPU 占用可忽略。
    static let pollInterval = 1.0 / 30.0

    func start() {
        let t = Timer(timeInterval: Self.pollInterval,
                      target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 几何

    /// 内建屏（带刘海的屏）。外接屏没有刘海，safeAreaInsets.top 为 0。
    func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// 刘海宽度（pt）。frame.width 减两侧辅助区，避免非主屏坐标错位。
    func notchWidth(for screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0 else { return 0 }
        let w = screen.frame.width - left.width - right.width
        return (w > 0 && w < screen.frame.width) ? w : 0
    }

    func notchCenterX(for screen: NSScreen) -> CGFloat { screen.frame.midX }

    /// 刘海热区：刘海本体 + 左右各 10pt 余量 + 往下延伸 40pt。
    /// 往下延伸是为了让「鼠标从上方快速划入」的路径也能命中。
    func hotZone(of screen: NSScreen, notchWidth w: CGFloat) -> NSRect {
        NSRect(x: notchCenterX(for: screen) - w / 2 - 10,
               y: screen.frame.maxY - screen.safeAreaInsets.top - 40,
               width: w + 20,
               height: screen.safeAreaInsets.top + 48)
    }

    /// 停留区：面板矩形（含 10pt 余量）+ 刘海热区。
    /// 必须有它：否则鼠标从刘海移进面板的瞬间会被判「离开热区」而收起。
    func isPointInStayRegion(_ p: NSPoint) -> Bool {
        if let frame = panelFrameProvider?(), frame.insetBy(dx: -10, dy: -10).contains(p) {
            return true
        }
        guard let screen = builtInScreen() else { return false }
        let w = notchWidth(for: screen)
        guard w > 0 else { return false }
        return hotZone(of: screen, notchWidth: w).contains(p)
    }

    // MARK: - 轮询

    @objc private func tick() {
        guard let screen = builtInScreen() else { return }
        let w = notchWidth(for: screen)
        guard w > 0 else { return }                 // 无刘海屏：仅菜单栏入口

        let p = NSEvent.mouseLocation
        // 按住鼠标时不触发，避免拖拽文件时面板乱闪
        if hotZone(of: screen, notchWidth: w).contains(p), (NSEvent.pressedMouseButtons & 1) == 0 {
            onEnterHotZone?()
        } else if !isPinned, !isPointInStayRegion(p) {
            onLeaveStayRegion?()
        }
    }
}
