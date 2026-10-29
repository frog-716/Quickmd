import AppKit

/// 菜单栏：5 项。
///
///   打开 / 关闭面板   —— 外接显示器（无刘海）时唯一的入口
///   打开文件列表      —— 展开成浏览态（等同面板里点「全部文件」）
///   打开 Markdown 文件…（⌘O）
///   选择工作文件夹…    —— 换一个目录当工作区，自动钉进快捷目录
///   开机自启          —— 勾选项，与系统「登录项」设置同步
///   退出 Quickmd      （⌘Q）
final class StatusMenu: NSObject {
    private let statusItem: NSStatusItem
    private let loginItem = LoginItemController()

    var onTogglePanel: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var onBrowse: (() -> Void)?
    var onChooseFolder: (() -> Void)?

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

        let browse = NSMenuItem(title: "打开文件列表",
                                action: #selector(browse), keyEquivalent: "b")
        browse.target = self
        menu.addItem(browse)

        let open = NSMenuItem(title: "打开 Markdown 文件…",
                              action: #selector(openFile), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let folder = NSMenuItem(title: "选择工作文件夹…",
                                action: #selector(chooseFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

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
    @objc private func browse() { onBrowse?() }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc private func toggleLaunchAtLogin() {
        let want = !loginItem.isEnabled
        let ok = loginItem.setEnabled(want)
        if !ok {
            NSLog("Quickmd: 开机自启切换失败")
        }
        rebuild()                                // 刷新勾选状态
    }
}
