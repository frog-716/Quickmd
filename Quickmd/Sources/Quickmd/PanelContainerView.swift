import AppKit

/// 面板的圆角容器：负责外观（圆角、底色、阴影）与「点击即激活」。
///
/// v3砍掉了「拖入 .md 文件打开」——菜单里 ⌘O 已经够用，拖拽带来的
/// 拖拽高亮反馈本来就是半残的（见 MAP.md 问题清单），不值得为它留代码。
final class PanelContainerView: NSView {
    /// 点击面板时回调（用于激活并接管键盘）
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()                                   // 先激活拿键盘，再传递事件
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// 柔和的投影，让面板像一张纸浮在桌面之上。
    /// 注意两点：
    /// 1) shadowPath 必须显式给，否则 AppKit 算不出轮廓，阴影会退化成方块或不显示；
    /// 2) 本视图不能开 masksToBounds（那样会把阴影一起裁掉），
    ///    WebView 的圆角改由它自己的 layer 负责（见 AppDelegate.setupWebView）。
    override func layout() {
        super.layout()
        guard let layer = layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }
}
