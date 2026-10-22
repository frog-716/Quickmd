# 基于 NotchNotes 改造「刘海呼出 + 快速备忘录同尺寸 MD 面板」技术可行性评估

> 评估日期：2026-10-21｜改造对象：开源项目 NotchNotes（github.com/oil-oil/NotchNotes）
> 目标：Mac 上「上滑并触碰刘海区域」呼出浮层，窗口尺寸与右下角呼出的「快速备忘录」一致。

---

## 一、结论先行

**技术上完全可行，且比预想更顺——你这台 Air 实测有刘海（我此前"无刘海"的判断是错的，已纠正），NotchNotes 的刘海触发是它的主场能力，改造点集中在三处：尺寸常量、定位逻辑、触发手势加方向判定。唯一真正的拦路虎不是技术，是协议：NotchNotes 仓库没有任何 LICENSE 文件。**

---

## 二、实测证据（本机核验，非推测）

| 项 | 实测结果 | 方法 |
|---|---|---|
| **有无刘海** | **有**。`safeAreaInsets.top = 32.0pt，hasNotch = true`，内建屏 1470×956pt | 本机 Swift 脚本读 NSScreen |
| **快速备忘录窗口尺寸** | **约 330 × 285pt（±5%）** | 用你截图里的交通灯按钮（标准间距 20pt）当标尺反推截图比例（1.5x），再用窗口投影阴影带定位四条边 |
| **NotchNotes 触发能力** | 已支持 Hover（悬停顶部中央）/ Click / 拖入三种触发 + Menu Bar Only 模式 | 官方 README |
| **技术栈** | Swift + AppKit（浮层/窗口层级/屏幕定位/顶部触发）+ SwiftUI（界面）+ UserDefaults（本地存储）+ 自研 MarkdownEngine（vendored）；SwiftPM 工程，`swift run` 可构建；macOS 14+；维护活跃至 2026-10 | 官方 README + commit 历史 |
| **License** | **无（GitHub API 返回 license: null，仓库无 LICENSE 文件）** | GitHub API |
| AppleScript 读窗口 | 被权限拦截（-10004），需辅助功能权限才能程序化读取快速备忘录 frame | 本机实测 |

---

## 三、技术路径（三处改造点）

### 3.1 触发：「上滑 + 触碰刘海」
NotchNotes 已有"悬停顶部中央"触发，缺的只是**方向判定**。推荐语义：**光标向上滑入刘海热区**，而非触控板双指上滑。

- **实现**：`NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged])` 全局监听鼠标移动——**鼠标事件的全局监听不需要辅助功能权限**（键盘事件才需要），NotchNotes 的零权限悬停就是这么做的。
- **方向判定**：维护最近 N 个采样点（带时间戳），当「Y 方向持续向上运动（速度超阈值，如 >800pt/s）+ 光标进入热区」才展开。热区 = 刘海水平范围（用 `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` 推算刘海宽度，**不要硬编码**），Y < `safeAreaInsets.top`。
- **迟滞防误触**：展开后光标离开热区 + 150–250ms 延迟才收起；或者加 3–5px 的进入缓冲带。
- **不推荐**触控板双指上滑（scrollWheel 全局监听同样零权限，但日常滚动页面全是上滑事件，误触率不可接受）。

### 3.2 窗口：尺寸与定位
- **载体**：NSPanel（NotchNotes 已有），改造点：
  - `styleMask`：去掉 `.titled`（borderless），保留可成为 key window 的能力（要打字，不能纯 `.nonactivatingPanel`）；
  - `level`：高于 `.statusBar`（刘海类 App 惯例，覆盖菜单栏区域）；
  - `collectionBehavior`：`[.canJoinAllSpaces, .fullScreenAuxiliary]`（所有空间可见 + 能盖在全屏 App 上）；
  - **尺寸常量 330 × 285pt**（本次实测），写成可配置项；
  - **定位**：水平中心对齐刘海中心，展开态从刘海下缘向下滑出（y = screen maxY − 热区高度 − 面板高度）。
- 刘海宽度获取：`screen.frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`，运行时读，天然适配未来机型变化。

### 3.3 数据层（对接你既有架构）
- NotchNotes 用 UserDefaults 存笔记 → 改成读写 `~/Documents/QuickMD/` 下的本地 .md 文件（此前已建好 scratch.md 管道）；
- 回写备忘录走已验证的稳定路径：快捷指令「追加 Markdown 到备忘录」（App 内放一个按钮，内部调 `shortcuts run` CLI）。

---

## 四、系统层面限制与风险

1. **⚠️ 协议缺失（最大风险，法律层面）**：NotchNotes 无 LICENSE = 默认保留所有权利。**直接 fork 改造再分发 = 侵权**。个人本机私用属灰色地带、风险极低，但不是"开源可自由改"。三条正路：① 给作者开 issue 请求 MIT 授权（92 star 的个人项目，大概率好说话）；② 只参考它的架构思路、代码自研（就是原 Q 便签方案）；③ 换 MIT 协议的 Open Sidenotes 当基底。
2. **全屏 App 场景**：`.fullScreenAuxiliary` 可覆盖全屏空间，但全屏下刘海被系统接管、菜单栏隐藏，热区行为和视觉需要专门测试；自动隐藏菜单栏开启时展开动画会突兀。
3. **多屏**：外接显示器没有刘海，热区逻辑必须只在 `safeAreaInsets.top > 0` 的内建屏启用（NotchNotes 最近 commit 显示它刚加过 display selection，有现成基础）。
4. **macOS 大版本演进**：刘海类 App 通病——系统更新可能改菜单栏/窗口层级行为。缓解：metrics 全部运行时读取，不硬编码。
5. **误触**：顶部中央是菜单栏 App 图标聚集区，纯 hover 会误触；上滑方向判定 + 迟滞是必要而非可选。
6. **分发**：NotchNotes 官方构建未公证（需右键打开）；自建自用无此问题。

---

## 五、工作量评估

| 阶段 | 内容 | 估时 |
|---|---|---|
| P0 | 克隆 → `swift run` 跑通，确认基线在这台 Mac 上正常 | 0.5 天 |
| P1 | 窗口尺寸改 330×285pt + 刘海中心定位 + 展开/收起动画 | 0.5–1 天 |
| P2 | 上滑方向判定 + 热区 + 迟滞调参 | 1 天 |
| P3 | 数据层换 .md 文件 + 回写备忘录按钮 | 0.5 天 |
| P4 | 全屏/多屏/误触测试打磨 | 0.5–1 天 |
| **合计 MVP** | | **3–4 天** |

若因协议问题走自研（Q 便签方案），估算 1–2 周——NotchNotes 的价值在于让你**提前看到可工作的参照物**。

---

## 六、改造建议

1. **先走合规步**：给作者发 issue 问协议（一天内能拿到答复）。拿到 MIT → 直接改造，3–4 天交付；拿不到 → 把 NotchNotes 当架构参考，回到 Q 便签自研。
2. **尺寸做成常量 + 校准命令**：快速备忘录尺寸是 Apple 内部值，未来可能变；330×285pt 是今天的实测，App 里留一个"校准"开关即可。
3. **手势手感单独调**：上滑判定的速度阈值和迟滞时长没有理论值，只有手感值，预留半天专门调参。
4. **别动它的 MarkdownEngine**：vendored 的渲染引擎是现成资产，这是选 NotchNotes 而非从零写的核心理由。
