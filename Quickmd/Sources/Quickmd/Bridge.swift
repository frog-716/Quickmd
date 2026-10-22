import WebKit

/// JS → Swift 的消息通道。
///
/// v2 直接让 AppDelegate 当 WKScriptMessageHandler，会形成引用环：
///   AppDelegate → webView → configuration → userContentController → AppDelegate
/// 常驻进程里这个环不会崩，但属于隐患（v3 用弱引用包一层消掉）。
///
/// 消息只有两类：`ready`（编辑器就绪，可以推内容了）、`save`（带序列化好的 md）。
protocol BridgeDelegate: AnyObject {
    func handle(message: WKScriptMessage)
}

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var delegate: BridgeDelegate?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.handle(message: message)
    }
}
