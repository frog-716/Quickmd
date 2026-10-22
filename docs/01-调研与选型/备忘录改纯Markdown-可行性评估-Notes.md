# 备忘录（macOS Notes）改纯 Markdown 编辑格式 — 技术可行性评估

> 只读分析，未修改任何代码或数据。检查对象：`/System/Applications/Notes.app`

## 结论先行

1. **直接改 Notes.app 本体为纯 MD 编辑器：不可行。** 系统应用、无源码、Apple 平台签名 + SIP 保护，任何 patch 都会导致签名失效无法启动，且系统升级即还原。**不要尝试。**
2. **让备忘录工作流以纯 Markdown 运转：可行，且当前系统已内置全部官方积木。** macOS 26.5 的备忘录支持「导入 Markdown → 备忘录」和「导出备忘录 → .md」，快捷指令也有两个 Markdown 意图。
3. **但备忘录内编辑仍是富文本**：敲 `**粗体**` 不会渲染，没有实时预览/源码模式。想要 MD 编辑体验，编辑动作必须放在外部编辑器（Obsidian/iA Writer 等），或换一个以 MD 为核心的原生 App。
4. 推荐路径：**外部 MD 编辑器 + 官方导入/导出 + 快捷指令流水线**，零开发、零数据迁移成本。

## 检查对象与方法（全部只读）

| 项目 | 实测值 |
|---|---|
| 系统 | macOS 26.5（Build 25F71） |
| Notes.app 版本 | 4.13（3146.121.7），签名时间 2026-04-22 |
| 签名 | Apple 平台二进制（Platform identifier=26，TeamIdentifier 未设置），universal x86_64 + arm64e |
| 检查手段 | `sw_vers`、plist 读取、`otool -L`、`codesign -dv/--entitlements`、`strings`；数据目录访问被系统拒绝 |

数据目录 `~/Library/Group Containers/group.com.apple.notes/` 与沙盒容器 `~/Library/Containers/com.apple.Notes/` 均返回 **Operation not permitted**——备忘录库受 TCC + App 沙盒双重保护，任何第三方工具要读它必须拿到「完全磁盘访问权限」。

## 现有架构

```
Notes.app (Swift/ObjC, 15MB 主二进制)
├── 编辑层：AppKit TextKit（NSTextView + NSAttributedString 富文本）
│   ├── NotesEditor / NotesUI / NotesHTML（私有框架，HTML↔富文本）
│   ├── MarkupUI / PaperKit（标注、速绘）、VisionKit（扫描、实况文本）
│   └── LocalAuthentication + ICNoteLockManager（锁定备忘录，独立密码加密）
├── 数据层：Core Data（ICNoteContext / ICNote，NSManagedObject）
│   └── NoteStore.sqlite（group.com.apple.notes 组容器，TCC 保护）
├── 同步层：InternalSwiftProtobuf + CloudKitCode / CloudKitCodeProtobuf
│   └── usernoted 守护进程 ↔ CloudKit（iCloud 多端同步、共享协作）
└── 扩展：IntentsExtension（快捷指令）、Sharing、QuickLook、Spotlight、Widget
```

要点：

- **编辑器是富文本内核，不是纯文本**。所有样式（标题/加粗/表格/清单）走 TextKit attributes 和「Aa」格式菜单，底层没有 MD 源码表示。
- 主二进制 strings 里 **Markdown 相关符号已存在**：`exporterForMarkdown`、`importMarkdown:`、`exportMarkdown:`、`ICMarkdownFlavor`（剪贴板 flavor）、`attributedMarkdownStringFromPlainMarkdown:error:`（MD→富文本解析）、`initForNotesMarkdown:`，以及界面文案「Markdown Export & Import」「Markdown export: Note is locked」「Markdown Export not Supported on watchOS」；IntentsExtension 里有 `CreateNoteFromMarkdown`、`AppendMarkdownToNote` 两个快捷指令意图。
- **不存在**「Copy as Markdown」「Markdown 预览/源码模式/实时编辑」相关符号——这是官方口径与本机实测一致的边界。

## macOS 26.5 备忘录 Markdown 能力清单（官方 + 实测）

| 能力 | 状态 | 说明 |
|---|---|---|
| 导入 .md → 备忘录 | ✅ 文件 → 导入 Markdown | MD 语法转为保留格式的富文本；批量导入可选保留文件夹结构 |
| 导出备忘录 → .md | ✅ 文件 → 导出为 Markdown | 附件导出为并列的资源文件夹，兼容静态站生成器 |
| 快捷指令 | ✅ 从 Markdown 创建备忘录 / 追加 Markdown 到备忘录 | IntentsExtension 提供 |
| 备忘录内直接写 MD 语法 | ❌ | `**粗体**`、`# 标题` 输入后就是纯文本字符，不渲染 |
| 实时预览 / 源码模式 | ❌ | 二进制中无相关实现 |
| 锁定备忘录 | ❌ | 导出被拒（"Markdown export: Note is locked"），需先解锁 |
| watchOS | ❌ | 不支持 Markdown 导出 |

## 若强行改 App 本体，需要什么（以及为什么不可行）

| 改动点 | 现实约束 |
|---|---|
| 阅读/修改源码 | 无源码，只能逆向二进制（违反 macOS 软件许可，且技术上门槛极高） |
| patch 二进制 | Apple 平台签名，AMFI 强制校验；patch 后 App 直接无法启动 |
| 修改 /System 下文件 | SIP 保护，需关闭 SIP（严重削弱系统安全性，不建议） |
| 换存储/编辑器实现 | 数据模型是未公开的 Core Data + CloudKit 同步协议；改格式 = 同步冲突、跨设备全乱 |
| 升级 | 任何系统更新覆盖回原版，所有 patch 归零 |

## 可行方案对比

| 方案 | 做法 | 成本 | 有损点 |
|---|---|---|---|
| A. 原生导入导出 | 备忘录 ↔ .md 双向转换，编辑器自选 | 0 开发 | 见下 |
| B. 外部 MD 编辑器 + 官方 I/O（推荐） | Obsidian/iA Writer/Typora/VS Code 里编辑 .md，需要时导入备忘录；反之导出 | 0 开发 | 同 A |
| C. 快捷指令双向流水线 | CreateNoteFromMarkdown / AppendMarkdownToNote 做成快捷指令，可接侧边栏/触控栏快速收集 | 小时级 | 同 A，且只覆盖「写入备忘录」方向 |
| D. 整个换 MD 原生备忘录 App | Obsidian / Bear 2 / iA Writer / FSNotes，用 A 做导入迁移 | 天级迁移 | 锁定备忘录、扫描件、速绘、共享协作、智能文件夹需人工核对 |
| E. 直改 Notes.app | 逆向 patch | — | **不可行，勿做** |

## 对现有功能与数据的影响

**会丢的（MD 转换有损，双向都有）**：GitHub 扩展语法、脚注、内联 HTML（被剥离）、front matter 元数据；导出时批量不重建文件夹树、附件变成「.md + 并列资源文件夹」的双文件结构；锁定备忘录、协作共享笔记在边界上会丢协作元数据。

**不会动的**：iCloud 同步本身（导入导出的 .md 文件不参与同步，备忘录本体同步照常）、锁定/解锁机制、扫描与速绘、智能文件夹、Spotlight 索引、Widget、Siri 意图、快速备忘录。

**没有的**：官方 API/工具能把外部改过的 .md「写回」备忘录并保留富文本——回写只能通过导入（= 新建/追加）或快捷指令，**双向同步不存在**。

## 潜在风险

1. **隐私暴露**：第三方工具直读 NoteStore.sqlite 必须给「完全磁盘访问权限」，等于把整个备忘录库交出去。优先用官方导入导出，规避这条。
2. **脚本脆弱**：iCloud/NoteStore schema 未公开文档化，随 macOS 小版本漂移（26.x 一直在动），直读数据库的导出脚本随时可能失效。
3. **数据安全**：直读/直写第三方工具一旦写坏 NoteStore，没有官方恢复工具；动手前先确认 iCloud 备份可用。
4. **法律与保修**：逆向/修改系统应用违反 macOS 许可，且随时可能被任何系统更新打断。
5. **体验断裂**：如果目标是「在备忘录里像 Typora 一样打字」，A/B/C 都做不到——那是编辑器形态差异，只能靠 D 解决。

## 最终结论

- 「把本地原生备忘录 App 改成纯 Markdown 编辑器」——**技术上不可行**（签名/SIP/闭源三重锁死），且没有必要。
- 「备忘录内容以纯 Markdown 格式编辑和流转」——**可行**，macOS 26.5 已提供官方导入导出与快捷指令积木，配合一个外部 MD 编辑器即可闭环，零数据迁移、零开发。
- 只有当核心诉求是「编辑时就是 MD 源模式」时，才建议走 D（换 App），导入时同样用备忘录自带的导出能力做迁移。
