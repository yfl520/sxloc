# 随行定位 Flutter 界面

Windows x64 原生 Flutter 桌面客户端，macOS 风格，简体中文。完整使用、依赖、架构和构建方法见上一层 `README-桌面版.md`。

推荐运行 `scripts/publish-flutter.ps1` 构建并把自包含后台放入 `core` 子目录。直接运行 `flutter run -d windows` 时，需要设置环境变量 `SUIXING_CORE`，指向已编译的 `SuixingLoc.Core.exe`。

当前包版本针对 Flutter 3.50.0 / Dart 3.14.0 固定；pubspec.lock 应保留在源码中。地图使用 flutter_map 直接绘制，不依赖 WebView。用户数据由后台保存在 `%LOCALAPPDATA%\SuixingLoc`。
