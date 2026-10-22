# Q 便签 · MVP 使用说明

> 自研 macOS 原生便签浮层。鼠标移到屏幕顶部刘海处即呼出面板，尺寸对齐系统「快速备忘录」。
> 零安装第三方依赖、零辅助功能权限、不占程序坞。

> **沿革注记（2026-10-22 迁移时补）**：本文是 **v1（纯文本编辑器）** 的说明，已被 v2 Markdown 版超越——
> 现行使用方式请看 `Q便签-v2-Markdown编辑器-实现说明.md` 与项目根目录 `README.md`。
> 项目已迁移至 `/Users/frog/Projects/Quick-md/`，App 更名为 **Quickmd**：文中 `QNotes/` → `Quickmd/`、
> `QNotes.app` → `Quickmd.app`、`~/Documents/QuickMD/` → `~/Documents/Quickmd/`、`QNOTES_DEBUG` → `QUICKMD_DEBUG`。

---

## 一、跑起来（3 步）

```bash
cd /Users/frog/WorkBuddy/2026-10-21-15-22-20/QNotes
./build.sh          # 编译并打包成 QNotes.app
open QNotes.app     # 启动
```

首次启动若被拦：右键 App →「打开」；或到「系统设置 → 隐私与安全性」点「仍要打开」。

**日常启动**：把 `QNotes.app` 拖进「应用程序」目录即可。也可以用 `build.sh` 生成后手动放置。

---

## 二、怎么用

| 动作 | 结果 |
|---|---|
| 鼠标移到**屏幕顶部正中的刘海处** | 面板滑出（330×285pt，挂在刘海正下方） |
| 鼠标移开 | 面板自动收起（此时是「预览态」，不抢你正在打的字） |
| **点击面板** | 接管键盘，可以正式输入（点击后会被「钉住」，不因移开鼠标而消失） |
| `Esc` | 关闭并保存 |
| 菜单栏 `Q` 图标 | 点击手动开/关面板（备用入口） |

**存放位置**：`~/Documents/QuickMD/scratch.md`
输入内容实时保存（0.5s 防抖），关面板时再存一次。**这就是你的 MD 源文件**，用任何编辑器都能打开。

---

## 三、已验证的事实（本机实测）

| 验证项 | 结果 |
|---|---|
| 编译 | `swift build -c release` 通过，无警告 |
| 打包 | `QNotes.app` 生成，ad-hoc 签名有效，Info.plist 校验 OK |
| 面板尺寸/位置 | frame = (570, 671, **330×285**) @ 屏幕 1470×956 —— 与快速备忘录一致 |
| 刘海检测 | 刘海宽 179pt，safeAreaInsets.top = 32pt，热区 x[635..834] y[884..964] |
| 键盘链路 | `isKeyWindow=true`、firstResponder = NSTextView、`NSApp.isActive=true` |
| 数据链路 | 写入 → 读回校验通过（中文/标题/列表完整往返） |
| 进程存活 | 启动后稳定运行，不崩溃 |

---

## 四、诊断开关

```bash
QNOTES_DEBUG=1 ./QNotes.app/Contents/MacOS/QNotes --show-now   # 启动即展开 + 打印 frame/键盘状态
QNOTES_DEBUG=1 ./QNotes.app/Contents/MacOS/QNotes --selftest   # 数据链路自检
```

日志写入 `~/Documents/QuickMD/qnotes.log`。

---

## 五、MVP 边界（明确没做的事）

- **编辑器是纯文本**，不是所见即所得。敲 `# ` 不会变成标题——飞书式渲染是 v2 的活（WebView + CSS）。
- **不回写备忘录**。v2 接「追加 Markdown 到备忘录」快捷指令（`shortcuts run`）。
- **只有一块暂存区**，没有多便签列表、没有按天分文件。
- 面板尺寸是常量（330×285）。快速备忘录尺寸若随系统版本变化，这里需要跟着校准。

---

## 六、v2 待办（按优先级）

1. **WYSIWYG 渲染**：WebView + CSS 打造飞书式皮肤（内核选型②）。这是「飞书云文档手感」的正解。
2. **备忘录回写**：面板内加按钮 → `shortcuts run` 调「追加 Markdown 到备忘录」。回写只用追加，别碰原地替换。
3. **多便签/按天分文件**：解决一块暂存区越攒越乱的问题。
4. **手感调参**：热区高度、迟滞时长、展开动画曲线——这些只有真机试才有感觉值。

---

## 七、为什么不用 NotchNotes

NotchNotes 完成了同样的事，但**仓库没有 LICENSE 文件**（GitHub API 确认 license: null），法律上默认保留所有权利，改造再分发有侵权风险。本项目是**参考其成熟做法后独立自研**：

- 学它的：30Hz 轮询 `NSEvent.mouseLocation`（零权限，比全局 mouseMoved 监听可靠）、`auxiliaryTopLeftArea/RightArea` 推算刘海宽度、hover 被动预览 vs 点击激活的分离、停留区判断。
- 不学它的：SwiftUI + 多文件架构、文件暂存区、思维导图等超范围功能。
