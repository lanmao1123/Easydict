# ClipboardHistory：F2 剪贴板历史（Raycast Clipboard History 对标）

日期：2026-08-27
状态：实施中
授权依据：用户提出需求并经四项决策问答确认，明确说「开始」，模式为
implementation。

## 需求（已对齐）

1. 快捷键 F2 立即打开剪贴板历史面板（与 F1 截图/F3 贴图/F4 复制路径组成
   功能键全家桶）。
2. 采集文字与图片；密码类内容（ConcealedType/Transient 标记）跳过不记录。
3. 永久存储于 `~/Library/Application Support/Easydict/Clipboard/`
   （SQLite 库 + images/ 文件夹）；默认展示最近 7 天，可查全部，支持关键词
   搜索；类型筛选 All/Text/Image。
4. 回车 = 写回剪贴板 + 模拟 ⌘V 自动粘贴到前台应用；未授予辅助功能权限时
   弹引导并退化为仅复制。
5. 容量策略：文字永久；图片默认永久，设置提供「超过 X GB 从最旧清理」开关
   （默认关）；去重（相同内容置顶）。
6. UI 对标用户提供的 Raycast 截图：搜索框+类型筛选、列表（文字首行预览/
   图片缩略图+尺寸+相对时间+来源应用）、右侧信息预览面板、底部快捷键提示栏；
   ↑↓ 导航、⌘1~9 直选、⌘⌫ 删除、ESC 关闭。

## 关键技术事实

- macOS 无剪贴板变更通知，0.5s 轮询 `NSPasteboard.general.changeCount`
  为业界标准（Raycast/Maccy 同款），轻量不耗电。
- 项目无 SQLite 先例；使用系统自带 `import SQLite3`（libsqlite3），零新依赖。
- 功能键热键用 FunctionKeyHotKeyCenter（Magnet fn 标志坑已解决）；快捷键
  七处登记清单以 snipTools 为模板；老环境默认键迁移需独立 applied flag
  （snipToolsDefaultsApplied 已为 true 的环境不会再进旧迁移）。
- 自动粘贴 = CGEvent 合成 ⌘V 发前台应用，需辅助功能权限
  （AXIsProcessTrusted 检测 + 系统设置引导）；未授权退化仅复制。
- 面板需接收键盘输入（搜索），与贴图 panel 不同：唤起时激活并成为 key。

## 新增文件

`Easydict/Swift/Feature/ClipboardHistory/`：
- ClipboardEntry.swift（条目模型）
- ClipboardStore.swift（SQLite 存储层：建表/插入/查询/搜索/删除/去重/
  容量统计，hash 去重置顶，文件随删）
- ClipboardMonitor.swift（changeCount 轮询、类型判定、敏感跳过、来源应用
  记录、后台队列落库、回环防护）
- ClipboardManager.swift（编排：启动监听、面板开关、选中→复制+自动粘贴）
- ClipboardPanel.swift + ClipboardHistoryView.swift（Spotlight 式面板）
- ClipboardAutoPaster.swift（CGEvent ⌘V 合成与权限检测）

`EasydictTests/Feature/ClipboardHistory/ClipboardStoreTests.swift`

## 修改文件

ShortcutAction.swift（case + 配置）、Defaults.Keys+Extension.swift（快捷键
key + clipboardDefaultsApplied + 图片上限设置）、ShortcutManager.swift /
ShortcutManager+Default.swift（默认 F2 迁移）、KeyHolderWrapper.swift、
MenuItemView.swift、AppDelegate（启动接线）、Localizable.xcstrings（新 key
六语种）、project.pbxproj。

## 执行批次

A 存储引擎+采集监听（ClipboardEntry/Store/Monitor + 单元测试）→
B 快捷键登记+面板壳（F2 唤起、空列表）→
C 完整 UI（搜索/筛选/列表/预览/键盘导航/删除）→
D 自动粘贴+权限引导+六语种+文档归档+部署交验。

进度（2026-08-27）：
- A/B/C/D 主体全部落地：7 个源文件 + 1 个测试文件（ClipboardStoreTests
  10 例）。快捷键七处登记完成（F2 独立迁移 flag）；启动接线挂
  ShortcutManager.setupShortcut（Swift 侧装配点，ObjC 零触碰）。
- 键盘导航（↑↓/回车/ESC/⌘1-9/⌘⌫）用 Panel 级本地 keyDown monitor 实现，
  搜索框保住 first responder 的同时拦截功能键。
- SwiftLint function_parameter_count 修正：插入参数收敛为 PendingRow 结构体。
- 测试驱动出真实 bug：同秒同内容图片文件名撞车会被 dedup 误删——
  makeImageFileName 增加 -N 唯一后缀修复。
- xcstrings 新增 20 key 六语种；pbxproj 登记通过 plutil 校验。
- 30/30 测试全绿（Clipboard 10 + Annotation 15 + Pasteboard 5）。
- 无头自测通过（2026-08-27 16:2x）：启动 F2 注册（keyCode=120）；文字/图片
  采集入库（来源应用、尺寸、缩略图正确）；同内容去重置顶+旧文件清理；
  菜单唤起面板 720×480 可见；回车选择→文字/图片写回剪贴板均验证成功；
  面板关闭正常；真实使用流量（用户侧复制）已自动入库。
- 测试驱动修复两处真实缺陷：同秒同内容图片文件名撞车（-N 唯一后缀）、
  面板二次打开时 key 窗口时序抖动导致键盘失效（守卫放宽为可见即拦截，
  与 Spotlight 行为一致）。
- 待用户 GUI 验证：F2 物理键唤起、搜索打字过滤、筛选交互、自动粘贴
  （需授权辅助功能；未授权自动降级为仅复制）。

## 约束

- 全部新代码 Swift；不引第三方依赖；ObjC 冻结区零触碰。
- 提交推送需用户明确发话；验证沿用 xcodebuild + /tmp/ezd-dd + 用户 GUI 验证。
