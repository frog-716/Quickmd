<p align="center">
  <img src="docs/images/banner.png" alt="Quickmd" width="100%">
</p>

<h1 align="center">Quickmd</h1>

<p align="center">
  <b>刘海一碰就出来的 Markdown 快速便签。</b><br>
  不换 App · 不占程序坞 · 内容就是纯 <code>.md</code> 文件
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-orange">
  <img alt="Size" src="https://img.shields.io/badge/App-~1.3MB-lightgrey">
  <img alt="RAM" src="https://img.shields.io/badge/RAM-~34MB-green">
</p>

---

## 这是什么

Quickmd 是一个常驻 macOS 菜单栏的超小工具：把鼠标移到屏幕顶部**刘海**上，一块便签面板就会滑出来。点一下直接打字，**Esc 收起，内容已自动存盘**。

它想解决的问题很简单——**记一句话不该打开一个 App**。所以它没有主窗口、不占程序坞、不需要切换应用；写下的内容就是普通 Markdown 文件，落在 `~/Documents/Quickmd/`，任何编辑器都能打开。

<p align="center">
  <img src="docs/images/ui.png" width="560" alt="Quickmd 界面">
</p>

## 🎬 工作流程

<p align="center">
  <img src="docs/images/flow.png" width="100%" alt="工作流程">
</p>

从碰到刘海到内容落盘，全程无需切换 App、无需手动保存。

## ✨ 主要特性

- **刘海即入口**：鼠标碰到刘海本体（实测 179×36pt 热区）即唤出，误触低；30Hz 轮询鼠标位置，**零辅助功能权限**。
- **分块 WYSIWYG**：备忘录式手感，敲 `#` 前缀立刻变形，**光标不跳**。
- **无工具栏**：界面只剩编辑区，所有格式靠「前缀语法 + 快捷键」，干净直接。
- **自动存盘**：停笔约 0.2 秒自动原子写盘，Esc 收起时也会立即保存。
- **纯 `.md`**：文件落在 `~/Documents/Quickmd/`，不锁定、不加密、不依赖本 App。
- **极小极轻**：App 约 1.3MB，日常内存约 34MB。
- **开机自启**：菜单栏可随时开关（`SMAppService`，失败自动降级 `LaunchAgent`）。

## 🚀 快速开始

需要 macOS 14+ 与 Xcode Command Line Tools（无需完整 Xcode）。

```bash
cd Quickmd
./build.sh            # swift build + 打包 .app
open Quickmd.app      # 运行
```

> 首次运行会在 `~/Documents/Quickmd/` 创建一张空白便签 `scratch.md`。

### 开发模式

```bash
cd Quickmd
./dev.sh              # 退出旧版 → 重建 → 启动最新代码
./dev.sh stop         # 仅退出
./dev.sh --show-now   # 重建启动并带诊断参数
```

## ⌨️ 怎么用（速查）

**没有工具栏。** 格式靠「敲前缀自动变形」或「快捷键」。

| 想要 | 敲这个 | 快捷键 |
|---|---|---|
| 一 / 二 / 三级标题 | `# ` `## ` `### ` + 空格 | ⌘1 / ⌘2 / ⌘3 |
| 有序列表 | `1. ` + 空格 | ⌘8 |
| 无序列表 | `- ` 或 `* ` + 空格 | ⌘7 |
| 任务清单 | `- [ ] ` / `- [x] ` + 空格 | 点勾选框切换 |
| 引用 | `> ` + 空格 | ⌘9 |
| 加粗 / 斜体 / 删除线 | `**文**` `*文*` `~~文~~` | ⌘B / ⌘I / ⇧⌘X |
| 分隔线 | `---` | — |
| 续号 / 缩进 | 回车自动续号 | Tab / ⇧Tab |
| 打开别的 .md | — | ⌘O |
| 收起（自动存盘） | — | Esc |

> **有序列表按 Typora 的规矩**：写 `1. ` 回车变 `2.`，再回车变 `3.`；写 `3. ` 就从 3 开始，存盘重开后序号不丢。空列表项上再回车则退出列表。

## 🗂 项目结构

```text
Quick-md/
├── Quickmd/                # App 源码（SwiftPM，无 Xcode 工程）
│   ├── Sources/Quickmd/    # 入口 / 面板 / 编辑器 / 刘海触发 / 存储 / 菜单栏
│   ├── Resources/          # editor-core.js（纯函数内核）/ editor.js / html / css
│   ├── build.sh / dev.sh
│   └── Tests/              # 79 项 Node 单测
├── assets/icons/           # 应用图标
├── tools/                  # 图标生成脚本（可复现）
├── docs/                   # 调研与实现说明
└── MAP.md                  # 项目地图
```

## ⚠️ 已知边界

- 不支持表格 / 图片 / 脚注 / 公式（刻意砍掉，快速便签用不到）。
- 代码块无语法高亮（保留语言标签）。
- 单活动文档：打开新文件即切换。
- 面板尺寸固定 330×285（刘海下面就那么大）。

---

<p align="center"><sub>Quickmd · Markdown at the notch · macOS menu bar</sub></p>
