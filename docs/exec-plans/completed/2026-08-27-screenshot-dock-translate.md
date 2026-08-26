# 截图贴边对照翻译（Screenshot Dock Translate）

**状态:** completed
**最后复核:** 2026-08-27
**类型:** 新功能实现计划

## 实际结果（2026-08-27）

- M1/M2/M3 全部完成：模块四文件、快捷键注册、pbxproj 登记（5 个新文件，含测试）、
  xcstrings 九条六语言、布局测试 10 例。
- 实施中的偏差与调整：
  - 按仓库 Swift 迁移政策，未新增 EZWindowManager ObjC 方法，改为
    `ShortcutAction` 配置闭包直调 Swift 单例（计划已预判）。
  - 测试 Agent 反向审查发现 `dockedPanelOrigin` 垂直钳制只钳原点不保证整面板
    在屏内，已修正为 `min(y, max(innerBounds.minY, innerBounds.maxY - height))`
    并同步测试断言。
  - 环境问题（非本任务代码引起，未修改仓库配置）：`BuildTools/.build` 残留仓库
    搬家前的绝对路径缓存导致 SwiftFormat 工具编译失败，已删除缓存；xcodebuild
    使用外部 `-derivedDataPath` 避免仓库内 `build/` 产物被 SwiftLint 扫描
    （`.swiftlint.yml` 只排除大写 `Build/*`）。
- 验证：`xcodebuild build`（Debug, 外部 DerivedData）BUILD SUCCEEDED；
  `xcodebuild test -only-testing:EasydictTests/ScreenshotDockLayoutTests`
  10/10 通过；`git diff --check` 通过；xcstrings `jq -e .` 通过；SwiftFormat
  与 SwiftLint 构建阶段通过（格式化仅作用于新文件）。
- 未验证边界：真机 GUI 手动交互（快捷键触发、面板拖动、点击外部关闭）未自动化，
  交付后需人工验证一次。


## 任务契约

- Goal：新增独立快捷键触发的截图翻译模式——框选屏幕区域后原位不动，紧挨选区弹出
  非激活、可拖动的结果面板，自动 OCR + 翻译并在其中显示译文；点击外部或 ESC 关闭。
- 用户确认的决策：独立模式+快捷键（默认 ⌥+X，现有 ⌥+S 行为不变）；整段/分块显示，
  不做句子级对齐；只用第一个启用的翻译服务。
- Mutation authorization：worktree 允许（已批准计划范围）。
- Delivery authorization：auto-local-commit（验证通过后自动本地提交，不 push）。
- Allowed paths：
  - 新增 `Easydict/Swift/Feature/ScreenshotDockTranslate/`（4 个文件）
  - 新增 `EasydictTests/ScreenshotDockLayoutTests.swift`（委托独立 Agent 编写）
  - 修改 `ShortcutAction.swift`、`Defaults.Keys+Extension.swift`、
    `ShortcutManager+Default.swift`、`KeyHolderWrapper.swift`、
    `Easydict.xcodeproj/project.pbxproj`、`App/Localizable.xcstrings`
  - 治理文档：本计划与 `docs/histories/2026-08/` 记录
- Forbidden actions：不修改任何 Objective-C 文件（仓库迁移政策禁止扩展 ObjC）；不 push；
  不触碰现有 ⌥+S / ⌥+⇧+S 链路行为。

## 关键设计决策

1. **入口**：`ShortcutAction.configurations` 闭包直调
   `ScreenshotDockManager.shared.start()`（先例：`AppleOCREngine().pasteboardOCR()`），
   不新增 EZWindowManager ObjC 方法，规避迁移政策限制。
2. **选区定位**：复用 `Screenshot.lastScreen` + `lastScreenshotRect`（该屏局部坐标、
   左上原点，performScreenshot 在回调前写入），由纯函数
   `ScreenshotDockLayout.globalRect(fromLocalRect:in:)` 换算为全局左下原点坐标。
3. **面板**：`NSPanel` 子类，styleMask `[.borderless, .nonactivatingPanel]`、
   level `.floating`、`isMovableByWindowBackground`；SwiftUI 内容经
   NSHostingController 装载。三态：识别中 → 翻译中 → 结果/失败。
4. **自动关闭**：面板期间自持局部+全局 NSEvent 监听，local 用 windowNumber 判命中，
   点击窗外或 ESC 即 dismiss 并移除监听。
5. **OCR+翻译管线**：临时 `QueryModel`（ocrImage）+ `DetectManager.ocrAndDetectText`；
   服务取 `LocalStorage.enabledServices(.main)` 中第一个
   `enabledQuery && enabledAutoQuery && supportedQueryType 含 .translation` 的服务；
   目标语言按 `EZLanguageManager.userTargetLanguage(withSourceLanguage:)`；
   调用 `service.translate(_:from:to:) async`。
6. **测试职责分离**：布局纯函数的单元测试委托给另一个 Agent 编写（testing.md 规则）。

## 里程碑与验证

| # | 内容 | 验证 |
| --- | --- | --- |
| M1 | 模块四文件 + 快捷键注册五处 + xcstrings 六语言 | 编译通过 |
| M2 | 单元测试（坐标换算/贴边钳制） | `xcodebuild test -only-testing:EasydictTests/ScreenshotDockLayoutTests` |
| M3 | 整体验证 | `xcodebuild build`；`git diff --check`；xcstrings `jq -e .`；swiftformat lint |

## 已知限制与风险

- 默认键位仅首次启动写入（`Defaults[.firstLaunch]` 门控）；已有配置的老环境需在设置页
  手动录制一次 ⌥+X。
- 非激活面板内不可用光标选择文本（需要 key window），以「复制」按钮替代。
- 若左右两侧都放不下（窗口宽度极限），钳制后会与选区轻微重叠，保持可见优先。
