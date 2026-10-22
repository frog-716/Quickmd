import WebKit

/// 内嵌编辑器：把「点击」转成「激活」。
///
/// WKWebView 铺满整个面板，点击落在它身上时容器的 mouseDown 不会触发，
/// 面板就永远停在「预览态」（canBecomeKey=false）拿不到键盘，打不了字。
/// 这里在 WebView 自己的 mouseDown 里先激活，再照常把事件传给 WebKit。
///
/// （v1/v2 自检走的是显式激活路径，覆盖不到这条真实用户路径，
///   教训记在 memory/项目历史决策.md。）
final class EditorWebView: WKWebView {
    /// 点击时回调（用于激活面板）。由调用方决定是否抢焦点。
    var onActivateClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivateClick?()
        super.mouseDown(with: event)
    }
}
