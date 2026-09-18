## 2026-09-18 | 任务：修复贴图输入与 OCR 回调生命周期

**Links:** [执行计划](../../exec-plans/completed/2026-09-18-pin-input-lifecycle.md)

### 用户请求

继续排查截图、贴图和 OCR 的稳定性与性能问题。

### 变更

- 移除最后一张贴图关闭后遗留的系统唤醒观察者。
- 让手势 event tap 的回调对象只由 `PinImageManager` 持有，消除每轮贴图生命周期的一次额外 retain。
- 统一自动打码成功、空结果和异常的主线程完成回调；人脸和人体识别执行失败时也会结束请求。

### 设计意图

贴图输入监听只应在至少有一张贴图时存在，关闭最后一个面板必须完整释放相关资源。OCR 回调始终返回 AppKit 主线程，使覆盖层状态不依赖 Vision 的回调队列。

### 验证

- `git diff --check`：通过。
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`：通过；仅保留既有非严重 SwiftLint 和 AppIntents 元数据提示。
- 手动检查：未重新启动 Debug app，避免影响现有 TCC 授权。

### 受影响文件

- `Easydict/Swift/Feature/SnipTools/PinImageManager.swift`
- `Easydict/Swift/Feature/MacshotCapture/Services/AutoRedactor.swift`

### 后续事项

- 在保持当前授权状态的正常运行应用中，手动验证重复打开/关闭贴图后 F3 缩放与睡眠唤醒后的手势恢复。
