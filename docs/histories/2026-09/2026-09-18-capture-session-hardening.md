## 2026-09-18 | 任务：加固截图会话与剪贴板检索

**Links:** [执行计划](../../exec-plans/completed/2026-09-18-capture-session-hardening.md)

### 用户请求

排查并修复截图、贴图、OCR 和翻译的会话问题；使剪贴板默认显示全部历史，并可选地检索图片内文字，同时默认永久保留本地记录。

### 变更

- 重置复用截图覆盖层的 host-image 状态，并在结束截图后短暂抑制尾随的重复启动事件。
- 新截图翻译开始前取消旧任务，并在 OCR、语言检测和翻译阶段后检查取消状态。
- 剪贴板默认查询全部记录；使用 SQLite FTS5 索引文本与后台 OCR 的图片文字，且设置页默认不自动删除图片。
- 历史图片 OCR 按单张串行处理，避免在队列中积压大量图片数据。

### 设计意图

截图相关操作保持原有交互方式，但为复用 UI 和异步任务明确会话收尾边界。剪贴板搜索只读取本地已建索引，避免把 Vision OCR 放到用户输入路径中。

### 验证

- `git diff --check`：通过。
- `jq -e . Easydict/App/Localizable.xcstrings`：通过。
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`：通过；仅有既有的 AppIntents 元数据跳过警告。
- 临时数据库 FTS5 迁移与 `PRAGMA integrity_check`：通过，完整性结果为 `ok`。
- 手动检查：未替换或启动 Debug 应用，避免影响现有截图和辅助功能 TCC 授权。

### 受影响文件

- `Easydict/Swift/Feature/MacshotCapture/Overlay/OverlayView.swift`
- `Easydict/Swift/Feature/ScreenshotDockTranslate/ScreenshotDockManager.swift`
- `Easydict/Swift/Feature/SnipTools/SnipToolsManager.swift`
- `Easydict/Swift/Feature/ClipboardHistory/ClipboardHistoryView.swift`
- `Easydict/Swift/Feature/ClipboardHistory/ClipboardMonitor.swift`
- `Easydict/Swift/Feature/ClipboardHistory/ClipboardStore.swift`
- `Easydict/Swift/View/SettingView/Tabs/TabView/ClipboardTab.swift`
- `Easydict/App/Localizable.xcstrings`

### 后续事项

- 在不改变已授权应用与 TCC 状态的调试会话中，手动验证一次连续截图和图片文字检索。
