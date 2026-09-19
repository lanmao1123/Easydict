# 2026-09-19：剪贴板图片内存优化

## 目的

降低剪贴板图片在列表和预览中的解码内存，同时保留磁盘原图、复制/粘贴、OCR 检索和永久历史行为。

## 契约

- 允许修改剪贴板图片展示、缓存生命周期、Xcode 工程引用和对应治理文档。
- 不修改剪贴板数据库 schema、OCR 识别结果、历史保留策略或复制回写行为。
- 不替换或启动用户正在运行的正式应用。

## 变更

- 新增剪贴板图片加载器，使用 ImageIO 按显示尺寸降采样解码。
- 列表缩略图按约 160px 长边加载，预览图按约 1600px 长边加载。
- 使用 64 MiB `NSCache` 限制解码位图成本，解码队列最多并发 2 个任务。
- 删除单条记录、清空全部记录和切换存储目录时清理对应位图缓存。
- SwiftUI 使用 entry ID 驱动异步加载状态，避免行复用串图。

## 验证

- `git diff --check`：通过。
- `plutil -lint Easydict.xcodeproj/project.pbxproj`：通过。
- `xcodebuild build -workspace Easydict.xcworkspace -scheme Easydict -configuration Debug -derivedDataPath build2`：通过。
- 构建内建 SwiftLint：新增加载器无 warning；本次修复了新增 loader 引入的 Swift 6 并发 warning。

## 结果与限制

构建成功。该改动应减少大图在剪贴板 UI 中的解码内存和滚动压力，但尚未进行替换运行中应用的人工 GUI 回归；真实连续滚动、删除、切换存储目录和复制粘贴验证留待用户在安全环境中执行。
