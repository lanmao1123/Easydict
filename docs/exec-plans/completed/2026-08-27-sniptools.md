# SnipTools：F1 截图标注 + F3 贴图 + 取色器 + 复制图片路径

日期：2026-08-27
状态：completed
授权依据：用户已批准 ZCode 计划（plan 模式 ExitPlanMode 通过），模式为
implementation。后续用户明确要求提交并推送远程仓库。

## 目标

为 Easydict fork 融合 Snipaste 核心能力：

1. F1 截图 → 框选松手后原地进入标注编辑；工具条含矩形/椭圆/直线/箭头/
   铅笔/马克笔/下划线/文字/马赛克/高斯模糊/橡皮擦 + 撤销重做；出口：
   ✓ 复制图片、📁 存盘并复制绝对路径、⤫/ESC 取消。
2. F3 贴图：剪贴板图片置顶悬浮窗，滚轮缩放（0.05–20 倍）、拖动、双击关闭。
3. 取色器（⌥C）：放大镜 HUD 点击复制 HEX。
4. 复制图片路径（F4）：剪贴板图片落盘
   ~/Downloads/EasydictCaptures/YYYY-MM-DD/HH-mm-ss-SSS.png 并把 POSIX 绝对
   路径写入剪贴板；截图标注界面 📁 出口共用同一服务。
5. ESC 取消沿用现有 Screenshot 监听，零改动获得。

## P2 待续清单（本期不做，后续单独规划）

智能界面元素检测（AX + Vision 兜底）、贴图旋转/镜像/透明度/鼠标穿透/
GIF 播放、文本转贴图、贴图分组与自动备份、截图历史回放、标注对象事后
选中编辑、取色器局部坐标显示。

## 关键技术事实

- 四条现有截图快捷键汇于 `Screenshot.performScreenshot`
  （Easydict/Swift/Feature/Screenshot/Screenshot/Screenshot.swift:101），
  在此以会话开关分流不影响老入口；开关仿照 `shouldRestorePreviousApp` 先例。
- 遮罩挖洞＝整屏冻结快照 + 黑罩归零动画，框选后背景即高清底图，编辑复用
  overlay window 不另开窗；ESC/右键监听存活至 finishCapture，编辑期间兜底
  取消自动成立。
- Magnet/Sauce 支持 `KeyCombo(key: .f1)` 裸功能键；KeyHolder 录制控件放行
  功能键。物理 F 键被系统媒体键占用时需 Fn 组合或改自定义键。
- 剪贴板设施现成：NSPasteboard+Extension.image（file URL/PDF/TIFF/PNG）、
  NSImage.pngData()/writeToPasteboard()、EZToast.showText。
- 快捷键登记七步清单模板＝screenshotDockTranslate 全链。

## 新增文件

- `Easydict/Swift/Feature/SnipTools/`：SnipToolsManager.swift、
  PasteboardPathService.swift、PinImageManager.swift、PinImagePanel.swift、
  PinImageView.swift、ColorPickerPanel.swift
- `Easydict/Swift/Feature/ScreenshotAnnotate/`：AnnotationModel.swift、
  AnnotationCanvasView.swift、EditToolbarView.swift、MosaicRegionRenderer.swift
- `EasydictTests/SnipTools/PasteboardPathServiceTests.swift`
- `EasydictTests/ScreenshotAnnotate/AnnotationModelTests.swift`

## 修改文件

ShortcutAction.swift（case/globalActions/configurations）、
Defaults.Keys+Extension.swift、ShortcutManager+Default.swift、
KeyHolderWrapper.swift、MenuItemView.swift、Screenshot.swift（会话开关 +
completeEditing）、ScreenshotState.swift（isEditing）、
ScreenshotOverlayView.swift（editing 分支）、Screenshot+EventMonitor.swift
（编辑态禁用 D）、Localizable.xcstrings（新 key 六语种）、
project.pbxproj 登记。

## 设计决策

- 编辑阶段不另开窗：ScreenshotState.isEditing 分支替换选区手势层为画布+
  工具条；工具条 SwiftUI position 到选区下缘，复用 dock 翻译验证过的钳制
  算术思想。
- 显示与导出共享绘制抽象；马赛克= CIPixellate 区域预渲染图元，
  模糊= CIGaussianBlur 区域预渲染图元，橡皮擦= 删除相交项。
- 出图 = screen.takeScreenshot(selectedRect) 净图 + model.render 叠加；
  completeEditing(image:) 单一收口调 finishCapture 并复位 editModeEnabled。
- 编辑态禁用 D 键预览避免状态串扰。

## 执行批次

A 登记骨架 → B 存盘服务+贴图 → C 取色器 → D 编辑钩子壳 → E 标注引擎 →
F 本地化/测试/文档/交验。

进度（2026-08-27，全部完成）：
- A–F 批次全部落地。新增 `FunctionKeyHotKeyCenter`：Magnet 3.4.0 会给功能键
  强制加 fn 标志位导致 Carbon 热键永不匹配，改为裸功能键直注册解决 F1/F3/F4
  静默失效； ShortcutModifier 对多字素簇 keyEquivalent 容错避免启动崩溃。
- 马赛克/模糊为 Snipping Tool 式笔刷：一笔涂抹一个 undo 组，底图 tile 懒截取 +
  CIPixellate / CIGaussianBlur 分块渲染；mosaic 工具条图标自绘 3×3 像素网格，
  光标随笔刷尺寸变化。经日志插桩与用户实测确认可用。
- 文字工具三轮迭代后定稿：内联所见即所得输入（无卡片），原生 NSTextView 支持
  Enter 确认 / Shift+Enter 换行 / Esc 恢复，点中已提交文字可再次编辑、清空
  提交即删除；字号 S/M/L 循环按钮在文字工具激活时替换线宽按钮；工具图标改为
  字母 T。
- 其余修复：选区双色描边、⌘Z 撤销界面刷新、贴图 Retina 尺寸声明与原位贴回、
  触控板捏合缩放、编辑态 ESC/F3 键盘路由。
- 测试：AnnotationModelTests 15 例 + PasteboardPathServiceTests 5 例全绿；
  update/remove 重编辑路径有专门用例。

## 最终验证

- `xcodebuild build ... -derivedDataPath /tmp/ezd-dd`：BUILD SUCCEEDED。
- `xcodebuild test -only-testing:...AnnotationModelTests
  -only-testing:...PasteboardPathServiceTests`：20/20 通过。
- GUI 交互验证由用户亲自执行：马赛克涂抹、文字多行输入与重编辑等核心流程
  已确认可用。

## 已知限制

- P2 清单见上节（智能元素检测、贴图进阶、历史回放、形状对象事后编辑——文字
  已支持事后重编辑，其余形状未做）。
- 已有配置的老环境需在设置页手动录制一次新快捷键（一次性迁移仅覆盖默认值）。
