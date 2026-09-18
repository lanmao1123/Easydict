# 贴图输入监听生命周期修复

**Status:** completed
**Created:** 2026-09-18
**Updated:** 2026-09-18
**Owner:** Codex
**Links:** 无

## 任务契约

- 任务模式：`implementation`
- 用户目标：继续排查 F3 贴图及截图 OCR 自动处理的稳定性与长期性能问题。
- 允许动作：修复由当前源码证实的监听器、回调生命周期和 UI 回调线程缺陷，运行相称的本地构建验证。
- 允许修改路径：`Easydict/Swift/Feature/SnipTools/`、`Easydict/Swift/Feature/MacshotCapture/Services/`、本计划及对应历史记录。
- 预期交付物：贴图关闭后不再保留无用的唤醒观察者或事件 tap 回调对象；自动打码的成功、空结果和错误均可在主线程完成。

## 证据与范围

- `PinImageManager.installPinchTapIfNeeded()` 同时以属性和 `Unmanaged.passRetained` 持有同一个回调对象；成功安装时没有对应的 `release()`。
- `removeEventMonitors()` 会移除 timer、event tap 和 NSEvent monitors，但未移除 `wakeObserver`。
- `AutoRedactor` 的 Vision 空结果回调不保证在主线程运行；人脸和人体请求若 `perform` 抛错，没有终态回调。
- 不修改用户工作树中的 `PinImagePanel.swift`。

## 验证

- `git diff --check`
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`

## 里程碑

- [x] 确认泄漏路径及边界。
- [x] 释放所有贴图输入监听资源，并统一自动打码的 UI 回调线程与失败终态。
- [x] 完成构建验证、归档计划和历史记录。

## 验证结果

- `git diff --check`：通过。
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`：通过。项目既有 SwiftLint 输出为 11 条非严重提示、0 条 serious violation；AppIntents 元数据跳过警告仍存在。

## 进度记录

- 2026-09-18：事件 tap 改为由 `pinchTapBox` 单一持有，最后一张贴图关闭时移除唤醒观察者；AutoRedactor 的成功、空结果和 Vision 执行错误统一经主线程终态回调。
