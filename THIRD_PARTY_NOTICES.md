# 来源、第三方组件与许可

随行定位基于 [D1ngtalk/iap2loc](https://github.com/D1ngtalk/iap2loc)，原项目版权保留，修改源码按 GPL-3.0 提供，全文见 `LICENSE`。公开 Release 标签提供对应源码；Windows 运行目录另含 `licenses/iap2loc-GPL-3.0.txt`。原项目实现亦参考其注明的 [WinPlay](https://github.com/Roylyl/WinPlay)。

## 公开实验身份

实验身份来自 [DiPlay](https://github.com/shihabal3amri/DiPlay) 官方 [v0.2.22 Release](https://github.com/shihabal3amri/DiPlay/releases/tag/v0.2.22) 的 `DiPlay-0.2.22.apk`：

- APK SHA-256：`7d04db263834f22010a86847766928113d3503a273e4d2d3440d21552e173139`
- 资源路径：`assets/offline-mfi/identity.pk8` 与 `assets/offline-mfi/certificate.p7b`。
- 重建：执行 `scripts/import-desktop-identity.ps1`，也可用 `-ApkPath` 指向同一官方 APK；脚本验证以上哈希并恢复至已忽略的 `Desktop/Private/`。

仅提取这两个公开资源用于 iAP2 配件认证，未解除其他发布版本的机器绑定。DiPlay 对材料的说明指向公开 Carlinkit 固件；本项目不宣称取得 Apple MFi 授权，也不保证所有 iOS 版本接受。

测试二进制内嵌这些公开材料，可被提取，不应视作保密身份。源码不单独分发私钥和证书。Windows 还支持用户导入配套身份，验证 P-256 密钥与证书匹配后，使用当前用户 DPAPI 加密保存在 `%LOCALAPPDATA%/SuixingLoc/identity.dpapi`，不修改原始文件。

## 组件及在线服务

| 组件 | 用途 | 官方来源 |
| --- | --- | --- |
| Flutter / Dart | 界面及运行引擎 | https://flutter.dev / https://dart.dev |
| cupertino_ui / material_ui / cupertino_icons | 界面控件与图标 | https://pub.dev/packages/cupertino_ui / https://pub.dev/packages/material_ui / https://pub.dev/packages/cupertino_icons |
| flutter_map / latlong2 | 地图及坐标 | https://pub.dev/packages/flutter_map / https://pub.dev/packages/latlong2 |
| window_manager / screen_retriever / file_selector | 桌面窗口与文件选择 | https://pub.dev/packages/window_manager / https://pub.dev/packages/screen_retriever / https://pub.dev/packages/file_selector |
| path / crypto | 路径及完整性校验 | https://pub.dev/packages/path / https://pub.dev/packages/crypto |
| .NET / ProtectedData | Windows 核心与加密 | https://github.com/dotnet/runtime |
| Microsoft Visual C++ Runtime | Windows 原生依赖 | https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files |
| CPython 3.14.7 | 独立 USB 运行时 | https://www.python.org |
| pymobiledevice3 11.55.0 及依赖 | USB 开发者定位与镜像准备 | https://github.com/doronz88/pymobiledevice3 |
| Inno Setup | 可选中文安装器 | https://jrsoftware.org/isinfo.php |

实际 Dart 依赖见 `FlutterApp/pubspec.lock`。Windows 发布脚本收集 Flutter / Dart 包及 .NET SDK 的许可证到 `licenses/`；Flutter 自动许可集合位于 `data/flutter_assets/NOTICES.Z`。C++ 运行库来自 Visual Studio x64 CRT 可再分发目录，按 Microsoft 条款分发。

USB 依赖版本和 wheel SHA-256 见 `Bridge/UsbWorker/requirements.lock`。发布目录保留 CPython 许可、`licenses/usb-python/*.dist-info` 中的依赖许可与元数据，以及 `core/usb/Lib/site-packages` 中的原始许可。开发者镜像按上游组件来源在连接准备时下载缓存，不捆绑 Apple 系统镜像。清理说明文档时应保留这些许可证。

高德、OpenStreetMap 及 Photon 在线服务与数据遵循各自条款，不包含在项目代码许可证中。地图显示相应署名；高德 Web 服务 Key 由用户自行配置，不内置共享搜索 Key。开放地图数据来自 OpenStreetMap 贡献者，开放搜索默认使用 Photon。
