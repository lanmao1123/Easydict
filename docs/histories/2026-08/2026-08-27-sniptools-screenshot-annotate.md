# SnipTools：截图标注、贴图、取色器与复制图片路径

## 变更

- 新增 `Easydict/Swift/Feature/SnipTools/`（六文件）：F1 截图松手后原地进入
  标注编辑，工具条含矩形/椭圆/直线/箭头/铅笔/马克笔/下划线/文字/马赛克/
  高斯模糊/橡皮擦与撤销重做；出口 ✓ 复制图片、📁 存盘并复制 POSIX 绝对路径、
  ⤫/ESC 取消。F3 将剪贴板图片贴为置顶悬浮窗（滚轮与触控板捏合缩放 0.05–20 倍、
  双击关闭、编辑中直接贴回原选区）；⌥C 放大镜取色复制 HEX；F4 将剪贴板图片
  落盘 `~/Downloads/EasydictCaptures/YYYY-MM-DD/` 并把纯绝对路径写入剪贴板。
- 新增 `Easydict/Swift/Feature/ScreenshotAnnotate/`：快照式 undo/redo 标注模型
  （一笔涂抹一个 undo 组）、两遍合成器规避翻转坐标歧义；马赛克/模糊为微软
  Snipping Tool 式笔刷（CIPixellate / CIGaussianBlur 分块），光标随刷径变化；
  文字为内联所见即所得输入，Enter 确认、Shift+Enter 换行、Esc 恢复，点中已
  提交文字可再次编辑，清空提交即删除（带专门 update/remove 模型 API）。
- 新增 `FunctionKeyHotKeyCenter`：Magnet 会给功能键强加 fn 标志位使 Carbon 热
  键永不匹配，裸功能键直注册解决 F1/F3/F4 静默失效；ShortcutModifier 对多字素
  簇 keyEquivalent 容错避免启动崩溃。
- 快捷键四处登记 + Defaults keys + 默认键位一次性迁移（F1/F3/F4 裸键、⌥C）；
  `Localizable.xcstrings` 新增 20 个 manual key 六语种；pbxproj 登记全部新文件。

## 设计意图

- 编辑复用全屏 overlay window 不另开窗，冻结快照即高清底图，所见即所得且无闪断。
- 显示与导出共享同一绘制抽象（SwiftUI 视图镜像 AppKit render），出图时底图与
  标注一次性合成。
- 新代码全部 Swift，不触碰 ObjC 冻结区，符合仓库迁移政策。
- 文字重编辑走「隐藏原条目 + 草稿预填」路线而非通用对象选择系统，精准满足
  当前需求且不引入 P2 的复杂度。

## 验证

- `xcodebuild build -configuration Debug -derivedDataPath /tmp/ezd-dd`：
  BUILD SUCCEEDED。
- `xcodebuild test -only-testing:...AnnotationModelTests
  -only-testing:...PasteboardPathServiceTests`：20/20 通过。
- GUI 手动验证由用户执行：马赛克涂抹、文字多行输入、T 图标、字号切换等已
  确认可用；NSLog 插桩日志核实笔刷全链无失败记录。

## 受影响文件

- `Easydict/Swift/Feature/SnipTools/`（新增 6 文件）
- `Easydict/Swift/Feature/ScreenshotAnnotate/`（新增 5 文件）
- `Easydict/Swift/Feature/Shortcut/Model/FunctionKeyHotKeyCenter.swift`（新增）
- Screenshot 系列 4 文件（会话开关、状态、遮罩分支、键盘路由）、Shortcut 系列
  5 文件（登记、容错）、MenuItemView.swift、Defaults.Keys+Extension.swift
- `Easydict/App/Localizable.xcstrings`、`Easydict.xcodeproj/project.pbxproj`
- `EasydictTests/Feature/SnipTools/PasteboardPathServiceTests.swift`（5 例）
- `EasydictTests/Feature/ScreenshotAnnotate/AnnotationModelTests.swift`（15 例）
- `docs/exec-plans/completed/2026-08-27-sniptools.md`

## 后续事项

- P2 待续：智能界面元素检测、贴图旋转/透明度/穿透/GIF、贴图关闭恢复、历史
  回放、矩形填充模式、Shift 限定形状、非文字标注对象的事后编辑。
- 已有配置的老环境需在设置页手动录制一次新快捷键。
