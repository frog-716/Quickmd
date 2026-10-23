import AppKit

/// 菜单栏：v3 精简到 4 项。
///
///   打开 / 关闭面板   —— 外接显示器（无刘海）时唯一的入口
///   打开 Markdown 文件…（⌘O）
///   开机自启          —— 勾选项，与系统「登录项」设置同步
///   退出 Quickmd      （⌘Q）
///
/// v2 里的「在 Finder 中显示」被砍：极简优先，需要时用菜单栏图标右键
/// 或直接在访达里找 ~/Documents/Quickmd 即可。
final class StatusMenu: NSObject {
    private let statusItem: NSStatusItem
    private let loginItem = LoginItemController()

    var onTogglePanel: (() -> Void)?
    var onOpenFile: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let btn = statusItem.button {
            btn.title = "Quickmd"
            btn.toolTip = "Quickmd"
        }
        rebuild()
    }

    /// 重建菜单（开机自启状态变化后要刷新勾选标记）
    func rebuild() {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "打开 / 关闭面板",
                                action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let open = NSMenuItem(title: "打开 Markdown 文件…",
                              action: #selector(openFile), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let launch = NSMenuItem(title: "开机自启",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = loginItem.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Quickmd",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - 动作

    @objc private func togglePanel() { onTogglePanel?() }
    @objc private func openFile() { onOpenFile?() }
    @objc private func toggleLaunchAtLogin() {
        let want = !loginItem.isEnabled
        let ok = loginItem.setEnabled(want)
        if !ok {
            NSLog("Quickmd: 开机自启切换失败")
        }
        rebuild()                                // 刷新勾选状态
    }
}
