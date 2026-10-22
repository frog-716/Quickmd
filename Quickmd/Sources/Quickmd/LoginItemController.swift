import Foundation
import ServiceManagement

/// 开机自启（登录时自动启动）。
///
/// 主路径：`SMAppService.mainApp`（macOS 13+ 官方 API）。
///   注册后系统「设置 → 通用 → 登录项」里能看到并可手动关闭，
///   App 自己的菜单里也能勾选/取消，两边状态同步。
///
/// 兜底路径：LaunchAgent。
///   SMAppService 要求 App 处于受信任的安装位置且签名合规；
///   本地自编译（ad-hoc 签名）放在非标准路径时可能注册失败，
///   这时写一个 ~/Library/LaunchAgents plist 实现同样的效果。
///   两条路径互斥：开启其一必先关闭另一，避免重复启动。
final class LoginItemController {
    private let agentLabel = "com.quickmd.launch-at-login"
    private let fileManager = FileManager.default

    /// LaunchAgent plist 路径
    private var agentPlistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// 当前是否已开启开机自启（两条路径任一命中即为已开）
    var isEnabled: Bool {
        if serviceManagementEnabled { return true }
        return fileManager.fileExists(atPath: agentPlistURL.path)
    }

    /// 系统是否认得这个 App 的登录项
    private var serviceManagementEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 开启或关闭开机自启，返回是否成功
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        enabled ? enable() : disable()
    }

    // MARK: - 开启

    private func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            removeAgent()                       // 走官方 API 就不留 LaunchAgent
            return true
        } catch {
            NSLog("Quickmd: SMAppService 注册失败，降级为 LaunchAgent：\(error.localizedDescription)")
        }
        return writeAgent()
    }

    // MARK: - 关闭

    private func disable() -> Bool {
        var ok = true
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            // 没注册过就取消会报错，忽略即可（说明本来走的是 LaunchAgent）
            ok = false
        }
        removeAgent()
        return ok
    }

    // MARK: - LaunchAgent 兜底

    private func writeAgent() -> Bool {
        guard let appPath = Bundle.main.bundlePath as String? else { return false }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        do {
            try fileManager.createDirectory(at: agentPlistURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: agentPlistURL, options: .atomic)
            return true
        } catch {
            NSLog("Quickmd: LaunchAgent 写入失败：\(error.localizedDescription)")
            return false
        }
    }

    private func removeAgent() {
        try? fileManager.removeItem(at: agentPlistURL)
    }
}
