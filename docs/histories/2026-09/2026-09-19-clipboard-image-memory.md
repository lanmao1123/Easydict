# 2026-09-19 | 任务：剪贴板图片内存优化

**Links:** [执行计划](../../exec-plans/completed/2026-09-19-clipboard-image-memory.md)

### 用户请求

在不减少功能的前提下降低 App 内存和电量消耗；第一优先落地剪贴板图片展示的内存优化。

### 变更

- 新增 `ClipboardImageLoader`，用 ImageIO 在后台按显示尺寸解码图片。
- 列表缩略图按 160px 加载，预览图按 1600px 加载，磁盘原图继续用于复制和粘贴。
- 用 64 MiB `NSCache` 约束解码位图，并在删除、清空、切换存储目录时清理缓存。
- SwiftUI 异步加载状态改为按 entry ID 刷新，避免复用状态串图。

### 设计意图

剪贴板 UI 只需要显示尺寸的 bitmap；永久原图仍保存在磁盘，OCR 检索也继续基于已建立索引。这样保留功能，同时减少大截图造成的解码内存和滚动压力。

### 验证

- `git diff --check`：通过。
- `plutil -lint Easydict.xcodeproj/project.pbxproj`：通过。
- Xcode Debug 构建通过。
- 构建内建 SwiftLint 无新增 loader warning；新增代码引入的 Swift 并发 warning 已修复。

### 受影响文件

- `Easydict/Swift/Feature/ClipboardHistory/ClipboardImageLoader.swift`
- `Easydict/Swift/Feature/ClipboardHistory/ClipboardHistoryView.swift`
- `Easydict/Swift/Feature/ClipboardHistory/ClipboardManager.swift`
- `Easydict/Swift/Feature/ClipboardHistory/ClipboardMonitor.swift`
- `Easydict.xcodeproj/project.pbxproj`

### 后续事项

- 人工验证 F2 图片滚动、预览、删除、清空和切换存储目录。
- 后续继续处理 OCR 回填限批、OCR 输入降采样、剪贴板分页和搜索 debounce。
