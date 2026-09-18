## 2026-09-18 | 任务：隔离截图翻译启动会话

**Links:** [执行计划](../../exec-plans/completed/2026-09-18-dock-capture-session-generation.md)

### 用户请求

继续排查截图翻译的异常启动、卡住和体验不流畅问题。

### 变更

- 保存 Raycast 收起后启动截图的异步任务，使 `dismiss()` 能取消它。
- 为每轮截图翻译分配会话标识，在启动截图前和 capture completion 中拒绝过期任务。
- Raycast 等待循环在任务取消时立即结束，避免取消后持续忙等。

### 设计意图

截图翻译的会话边界从 OCR/翻译阶段前移到启动阶段。这样连续触发时，旧任务不能在延迟后抢占新的截图会话或把过期结果写入当前面板。

### 验证

- `git diff --check`：通过。
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`：通过；仅保留既有非严重 SwiftLint 和 AppIntents 元数据提示。
- 手动检查：未重新启动 Debug app，避免影响现有 TCC 授权。

### 受影响文件

- `Easydict/Swift/Feature/ScreenshotDockTranslate/ScreenshotDockManager.swift`

### 后续事项

- 在正常运行的已授权应用中连续触发两次截图翻译，确认第二次不会被首次 Raycast 等待任务抢占。
