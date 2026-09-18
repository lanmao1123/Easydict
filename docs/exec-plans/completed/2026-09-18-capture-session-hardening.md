# 截图会话复用与对照翻译并发加固

**Status:** completed
**Created:** 2026-09-18
**Updated:** 2026-09-18
**Owner:** Codex
**Links:** 无

## 任务契约

- 任务模式：`implementation`
- 用户目标：排查并修复截图、贴图、OCR 与截图翻译中导致卡住、串会话或体验不流畅的问题；剪贴板默认查询全部时间，支持可选的图片文字检索，并将文字和图片默认永久保留。
- 允许动作：审查相关运行时链路、修复已证实缺陷、运行相称的本地验证。
- 允许修改路径：`Easydict/Swift/Feature/MacshotCapture/`、`Easydict/Swift/Feature/ScreenshotDockTranslate/`、`Easydict/Swift/Feature/ClipboardHistory/`、本计划及对应历史记录。
- 预期交付物：会话状态不泄漏、后发截图翻译不会被旧异步任务覆盖、剪贴板默认查询全部历史且支持可选图片文字检索，并有验证报告。
- 验收标准：取消后的覆盖层不会遗留 host-image 自动模式；开始新翻译会取消并隔离旧流程；F2 默认显示实际全部历史，文本和图片 OCR 检索使用本地索引；新安装默认不自动删除图片；构建、格式检查通过。

## 自动提交状态

- 自动提交资格：`eligible`
- 初始暂存区：`empty`
- 自动提交结果：`not attempted`

## 输入来源

- 用户明确请求：全面排查并修复截图、贴图、OCR、翻译的漏洞与卡顿，特别关注截图后异常再开截图；剪贴板历史默认查询全部时间，按需检索图片中的文字，且文字和图片默认永久保存在本地。
- 仓库规则：`docs/agents/` 中的实现、验证和 Git 流程。
- 附件或引用材料：`Yaomao-开发交接文档.md` 的模块现状、无头验证方法与已知风险。
- 仅作为证据的内容：最新 Yaomao 运行日志与当前工作树。

## 目标

让复用的截图覆盖层和截图对照翻译具有明确的会话边界：取消不会遗留自动动作，新请求不会让旧的 OCR 或网络翻译写入新界面；让 F2 剪贴板历史默认覆盖全量记录，默认只搜文字，并在用户选择图片文字时通过已建索引检索而非实时 OCR。

## 范围

- 包含范围：覆盖层重置状态、截图对照翻译的启动、取消和异步结果隔离；剪贴板全时间默认值、全量列表、文本与图片 OCR 索引、图片保留默认值。
- 不包含范围：既有贴图拖动改动、视觉尺寸调校、外部服务配置、部署或推送。

## 背景

- 当前行为：覆盖层池会跨截图复用；`autoHostImageMode` 在 `reset()` 中未复位。截图对照翻译的新启动也未取消旧的 OCR/翻译任务。F2 默认只看近七天，且关键词使用 `LIKE '%...%'` 全表扫描、所谓“全部”还被 500 条上限截断；图片没有可检索 OCR 索引，默认保留数为 100。
- 相关文件：`OverlayView.swift`、`ScreenshotDockManager.swift`、`ClipboardHistoryView.swift`、`ClipboardStore.swift`、`ClipboardMonitor.swift`、`ClipboardTab.swift`、`Localizable.xcstrings`。
- 约束：保留现有串行翻译规则；不修改用户已有未提交的 `PinImagePanel.swift`。

## 风险与缓解

- 风险：取消后仍返回的底层 OCR 或网络请求可能写入下一轮界面。
  - 缓解措施：启动新会话时先取消旧任务，并在每个耗时阶段后检查取消状态，避免旧流程继续提交结果。
- 风险：已有剪贴板数据库没有全文索引。
  - 缓解措施：在建库路径中采用幂等 FTS5 表、触发器和一次性重建，使旧数据库无需手工迁移。
- 风险：对大量历史图片一次性 OCR 会竞争 CPU。
  - 缓解措施：新图片和旧图片均通过独立的低优先级串行队列处理；搜索只读取已完成的索引，绝不在输入路径同步 OCR。

## 里程碑

- [x] 确认范围和约束。
- [x] 实现覆盖层状态、翻译会话隔离和剪贴板全量检索。
- [x] 完成静态验证和验证记录；运行时手动复现留待不影响现有 TCC 授权的调试会话。
- [x] 将本计划移到 `completed/`。

## 验证

- 命令：`git diff --check`、`swiftformat --lint`、`xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`。
- 手动检查：用 Debug URL 触发一次截图翻译，并检查日志中的会话 token、取消和终态；不覆盖部署以避免重置 TCC 授权。
- 观察结果：`git diff --check` 和 String Catalog JSON 解析均通过；针对现有数据库副本的 FTS5 迁移探针可检索写入的图片 OCR 文本，`PRAGMA integrity_check` 返回 `ok`。`xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2` 已通过（仅有既有的 AppIntents 元数据跳过警告）。本机未安装 `swiftformat`，因此无法执行其 lint。未替换或启动 Debug 应用，避免影响现有截图与辅助功能 TCC 授权。

## 决策记录

- 2026-09-18：只修复从当前源码和运行日志能证明的会话边界缺陷；“复制后又开截图”尚无重复触发日志，不臆测剪贴板监听为根因。

## 进度记录

- 2026-09-18：已完成代码路径和最近运行日志审计，发现覆盖层 host-image 标记复位遗漏，以及新旧截图翻译流程可并发写入同一状态。
- 2026-09-18：完成覆盖层状态清理、截图翻译取消检查和 F1 收尾去重保护。剪贴板默认改为全时间，取消 500 条截断；SQLite FTS5 现在索引文本和图片 OCR 文本，历史图片走独立低优先级队列补建索引。图片默认永久保留，设置页可显式选择上限。
- 2026-09-18：将历史图片 OCR 回填改为逐张读取、识别和落库，避免将大量图片 `Data` 同时滞留在队列中。`git diff --check`、String Catalog JSON、临时库 FTS/完整性探针及 Debug 构建均通过；未部署、未提交。
