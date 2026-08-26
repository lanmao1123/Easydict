# 截图贴边对照翻译新功能

## 变更

- 新增 `Easydict/Swift/Feature/ScreenshotDockTranslate/` 模块（Layout/Manager/
  Panel/View 四文件）：独立全局快捷键（默认 ⌥+X）框选屏幕区域后，在选区旁贴边
  弹出非激活、可拖动的悬浮面板，自动完成 Vision OCR 与翻译并展示，点击面板
  外部或 ESC 关闭；现有 ⌥+S / ⌥+⇧+S 行为不变。
- 快捷键注册四处登记（`ShortcutAction` 枚举与配置、Defaults key、默认键位、
  `KeyHolderWrapper` 映射），设置页经 `globalActions` 自动渲染。
- `Localizable.xcstrings` 新增 9 条 key，补齐 en/es/ja/sk/zh-Hans/zh-Hant。
- `project.pbxproj` 登记 5 个新文件（含测试 target）。
- 新增 `EasydictTests/Feature/ScreenshotDockLayoutTests.swift`（10 例，由独立
  Agent 编写）：覆盖屏幕局部坐标到全局坐标的 Y 轴翻转换算与贴边位置钳制。

## 设计意图

- 译文来自用户主窗口启用列表中第一个支持文本翻译的服务，目标语言沿用
  `EZLanguageManager` 的偏好规则，与现有查询体验一致。
- 入口走 `ShortcutAction` 配置闭包直调 Swift 单例，不新增 Objective-C 代码，
  符合仓库 Swift 迁移政策。
- 布局数学独立为无 AppKit 依赖的纯函数（仅借用 NSRect 类型），便于单测覆盖。

## 验证

- `xcodebuild build -configuration Debug -derivedDataPath /tmp/ezd-dd`：
  BUILD SUCCEEDED（含 SwiftFormat 与 SwiftLint 构建阶段）。
- `xcodebuild test -only-testing:EasydictTests/ScreenshotDockLayoutTests`：
  10/10 通过。
- `git diff --check`、`jq -e . Easydict/App/Localizable.xcstrings` 通过。
- GUI 手动交互（触发、拖动、外部点击关闭）未自动化，需人工验证。

## 受影响文件

- `Easydict/Swift/Feature/ScreenshotDockTranslate/`（新增 4 文件）
- `Easydict/Swift/Feature/Shortcut/Model/ShortcutAction.swift`
- `Easydict/Swift/Feature/Shortcut/Model/ShortcutManager+Default.swift`
- `Easydict/Swift/Feature/Shortcut/View/KeyHolderWrapper.swift`
- `Easydict/Swift/Feature/Configuration/Defaults.Keys+Extension.swift`
- `Easydict/App/Localizable.xcstrings`
- `Easydict.xcodeproj/project.pbxproj`
- `EasydictTests/Feature/ScreenshotDockLayoutTests.swift`（新增）
- `docs/exec-plans/completed/2026-08-27-screenshot-dock-translate.md`

## 后续事项

- 已有配置的老环境需在设置页手动录制一次 ⌥+X（默认键位仅首次启动写入）。
- 若 `.swiftlint.yml` 后续想包容仓库内构建目录，可将 `build/`（小写）加入
  excluded；本次未改动该配置。
