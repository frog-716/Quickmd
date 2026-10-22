import AppKit

/// 面板的圆角容器：负责外观（圆角、底色）与「点击即激活」。
///
/// v3 砍掉了「拖入 .md 文件打开」——菜单里 ⌘O 已经够用，拖拽带来的
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
}
