import AppKit

/// 面板本体：分两态。
///
/// - 预览态（`allowsKeyActivation = false`）：鼠标划过刘海就滑出，但不抢键盘焦点，
///   别的窗口照常打字——这是「不打扰」的关键。
/// - 激活态（`allowsKeyActivation = true`）：点击后接管键盘并被「钉住」。
final class NotchPanel: NSPanel {
    var allowsKeyActivation = false

    override var canBecomeKey: Bool { allowsKeyActivation }
    override var canBecomeMain: Bool { allowsKeyActivation }
}
