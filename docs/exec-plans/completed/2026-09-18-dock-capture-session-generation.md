# 截图翻译启动会话隔离

**Status:** completed
**Created:** 2026-09-18
**Updated:** 2026-09-18
**Owner:** Codex
**Links:** 无

## 任务契约

- 任务模式：`implementation`
- 用户目标：消除截图翻译连续触发时的错乱和卡住风险。
- 允许动作：修复已证实的启动任务重入问题，并运行本地构建验证。
- 允许修改路径：`Easydict/Swift/Feature/ScreenshotDockTranslate/`、本计划及对应历史记录。
- 预期交付物：新启动会取消尚未开始截图的旧启动任务；旧 capture completion 不会写入新会话。

## 证据与范围

- `ScreenshotDockManager.start()` 在 Raycast 收起后使用未保存的 `Task` 调用 `Screenshot.shared.startCapture`。
- `dismiss()` 仅取消 OCR/翻译和读法任务，无法取消该启动任务；连续触发时，旧任务可在稍后发起截图。

## 验证

- `git diff --check`
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`

## 里程碑

- [x] 确认启动阶段重入路径。
- [x] 添加启动任务取消与会话标识。
- [x] 完成构建验证、归档计划和历史记录。

## 验证结果

- `git diff --check`：通过。
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`：通过。项目 SwiftLint 输出为 11 条非严重提示、0 条 serious violation；AppIntents 元数据跳过警告仍存在。

## 进度记录

- 2026-09-18：新增 `captureStartTask` 与 `activeSessionID`；Raycast 等待完成后、启动截图前及 capture completion 均核对会话标识。取消等待任务会立即退出 sleep，不再忙等到超时。
