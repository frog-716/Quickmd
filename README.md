# Quickmd

> 刘海一碰就出来的 Markdown 快速便签。不换 App、不占程序坞、不花钱。

## 这是什么

一个常驻macOS 菜单栏的超小进程：鼠标蹭一下屏幕顶部刘海 → 便签面板滑出（330×285pt，与系统「快速备忘录」同尺寸）→ 点一下就能打字 → Esc 收起，内容已自动存盘。

- **编辑器**：分块 WYSIWYG Markdown（飞书云文档式手感），敲 `#` 前缀即变形，光标不跳
- **数据**：纯 `.md` 文件落在 `~/Documents/Quickmd/`，任何标准 Markdown 工具都能打开
- **权限**：零辅助功能权限（30Hz 轮询鼠标位置，不用全局监听）
- **内存**：日常约 37MB，1286 块大文档也只 42MB（实测）

## 快速开始

```bash
cd Quickmd
./build.sh            # swift build -c release --disable-sandbox + 打包
open Quickmd.app      # 运行
```

> SwiftPM 需要 `--disable-sandbox`（build.sh 已内置）；无需 Xcode，纯 Command Line Tools 可构建。
> 首次运行会在 `~/Documents/Quickmd/scratch.md` 生成一份演示全部格式的示例便签。

## 使用

| 操作 | 方式 |
|---|---|
| 呼出 / 收起 | 鼠标碰刘海热区 / Esc |
| 激活打字 | 点击面板（预览态不抢键盘焦点） |
| 保存 | 停笔 0.4 秒自动存盘；⌘S 立即保存 |
| 打开其他 .md | 菜单栏 Quickmd 图标 →「打开 Markdown 文件…」或 ⌘O；也可直接拖入面板 |
| 快捷键 | ⌘B ⌘I ⇧⌘X ⌘E ⌘K ⌘S、⌘1/2/3 标题、⌘7/8/9 列表引用 |

完整规格见 [`docs/03-使用与实现/Q便签-v2-Markdown编辑器-实现说明.md`](docs/03-使用与实现/Q便签-v2-Markdown编辑器-实现说明.md)。

## 目录导览

```
Quick-md/
├── README.md                        ← 本文件
├── docs/
│   ├── 01-调研与选型/               # 前期调研：备忘录改 MD 可行性 ×2、中间层压力测试、
│   │                                #   工具选择手册、flomo 拆解
│   ├── 02-设计与方案/               # 技术方案、NotchNotes 刘海改造可行性
│   └── 03-使用与实现/               # MVP 使用说明、v2 实现说明（四项规格）
├── memory/
│   └── 项目历史决策.md              # 从第一天起的决策链与踩坑记录
├── references/
│   └── NotchNotes-参考项目说明.md   # 参考了哪些模块、license 风险、为什么只参考不 fork
└── Quickmd/                         # App 源码（SwiftPM）
    ├── Package.swift
    ├── build.sh
    ├── Info.plist
    ├── Sources/Quickmd/
    │   ├── main.swift               # AppKit 主程序（刘海几何/触发/桥接/菜单）
    │   └── Resources/               # editor.html / editor.js / editor.css
    └── Tests/editor-core.test.js    # 55 项 Node 单测
```

## 名称沿革

| 阶段 | 名称 | 说明 |
|---|---|---|
| MVP | Q便签 / QNotes | 纯文本编辑器，验证刘海触发链路 |
| v2 | Quickmd | Markdown 所见即所得，统一 App 名称（2026-10-22 迁移至本目录时定型） |

历史文档保留了原文件名（Q便签-*.md），内容未改动，以反映演进过程。

## 诊断开关

```bash
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --show-now    # 启动即展开 + 键盘自检
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --mdtest      # 真实 WebView DOM 往返测试
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --clicktest   # 合成点击，验证激活链路
QUICKMD_DEBUG=1 ./Quickmd.app/Contents/MacOS/Quickmd --blockcount  # 块数诊断
```

日志写在 `~/Documents/Quickmd/quickmd.log`。

## 已知边界

- 不支持表格 / 图片 / 脚注 / 公式（刻意砍掉，快速便签用不到）
- 代码块无语法高亮（语言标签仅保留）
- 单活动文档（打开新文件即切换）
- 「转正文」只有工具栏按钮，无快捷键
