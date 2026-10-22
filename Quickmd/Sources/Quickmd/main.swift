import AppKit

// Quickmd v3 · 入口
// ---------------------------------------------------------------------------
// 组件分工（都在 Sources/Quickmd/ 下，一个文件一件事）：
//   AppDelegate          组装与生命周期：把下面这些零件串起来
//   NotchPanel           面板本体：预览态 / 激活态两态切换
//   PanelContainerView   面板外观与「点击即激活」
//   EditorWebView        内嵌编辑器：把点击转成激活
//   NotchTrigger         刘海几何 + 30Hz 轮询（零权限）
//   DocumentStore        当前文档的读写（原子写）
//   Bridge               JS → Swift 消息通道（弱引用，不成环）
//   StatusMenu           菜单栏（含开机自启开关）
//   LoginItemController  开机自启（SMAppService，失败降级 LaunchAgent）
//   editor.js            网页编辑器内核（Resources/ 下）
//
// 权限：全程零辅助功能权限。触发靠 30Hz 轮询 NSEvent.mouseLocation。

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
