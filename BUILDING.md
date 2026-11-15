# 构建与发布

## 环境与构建

依赖版本以 `FlutterApp/pubspec.yaml`、`FlutterApp/pubspec.lock` 和 `Bridge/UsbWorker/requirements.lock` 为准。当前构建环境为 Flutter 3.50 / Dart 3.14、.NET 10 SDK、Visual Studio C++ 桌面工具与 Windows SDK；Android 使用 JDK 21 和 Android SDK 36。Windows USB 独立运行时为 CPython 3.14.7 x64 + pymobiledevice3 11.55.0；准备它需要本机 Python 3.14 x64 / pip。安装器额外需要 Inno Setup。

先恢复实验身份，脚本从固定的 DiPlay 官方 APK 提取并校验 SHA-256，详见 [来源与许可](THIRD_PARTY_NOTICES.md)。材料仅用于本机构建，不提交源码。

```powershell
./scripts/import-desktop-identity.ps1

# Windows 测试目录；按本机实际路径修改参数
./scripts/publish-flutter.ps1 `
  -Flutter C:\tools\flutter\bin\flutter.bat `
  -Dotnet dotnet -Python python `
  -BuildRoot C:\SuixingLocBuild -OutputRoot C:\SuixingLocTest -TestBuild

# Android APK；按本机实际路径修改参数
./scripts/build-android-test.ps1 `
  -Flutter C:\tools\flutter\bin\flutter.bat `
  -JavaHome C:\Java\jdk-21 -AndroidSdk C:\Android\Sdk `
  -BuildRoot C:\SuixingLocBuild -OutputRoot C:\SuixingLocAndroidTest
```

构建脚本将 Flutter 源码暂存到英文路径，避免原生工具的中文路径问题。输出目录必须使用新的位置，不覆盖已交付文件。Windows `-TestBuild` 仅生成完整运行目录；移除此参数会生成完整便携包、更新清单及源码 ZIP，提供 `-InnoCompiler` 时额外生成安装器。Android 脚本生成含三种 ABI 的 APK 并验证签名。脚本不启动应用、不安装 APK、不连接设备。

可通过 `-Version`、`-BuildNumber` 和 `-ProjectGithubUrl` 覆盖版本及项目地址。Android 入口为 `FlutterApp/lib/main_android.dart`，Windows 为 `FlutterApp/lib/main.dart`。旧 macOS CLI 的 `scripts/package-macos.sh` 和手动 CI 保留，不属于当前 Flutter 两端附件。

## 离线检查

在还原依赖的 Flutter 暂存目录运行：

```powershell
flutter analyze --no-pub
flutter test --no-pub
dart run tool/check_android_coordinates.dart
dart run tool/check_android_search.dart
```

Windows 更新包解压回归位于 `Tests/Updates`，通过 `dotnet run --project Tests/Updates/Updates.Tests.csproj` 执行；Android 构建脚本同时执行 JVM 协议测试。离线检查不代替真实地图数据、设备认证、系统定位效果及覆盖更新验证。

## 更新发布约定

应用仅在用户打开关于页并点击“检查更新”后访问本仓库 GitHub Releases，不自动检查、下载或安装。Windows 与 Android 版本独立，版本号相同时比较构建号。草稿、预发布和缺少平台前缀的标签不作为正式更新。

| 平台 | 标签示例 | 必需附件 |
| --- | --- | --- |
| Android | `android-v1.2.9+16` | `sxloc-android.apk`、`sxloc-update.json` |
| Windows x64 | `windows-v1.1.5+10` | `sxloc-windows-x64.zip`、`sxloc-update.json` |

当前测试附件以预发布提供；用户测试通过后再发布正式版。每个平台单独创建 Release，对应实际构建源码提交并提供版本说明。Windows ZIP 顶层必须为 `随行定位/`，保留完整程序、USB 运行时、许可及 `app_info.json`，不能只上传 EXE。

使用以下脚本复制安装文件并生成大小、SHA-256 和清单，不会上传：

```powershell
./scripts/prepare-update-release.ps1 -Platform android `
  -Package ./build/app.apk -Version 1.2.9 -BuildNumber 16 `
  -OutputDirectory ./release-android-1.2.9-16
```

清单格式（大小和哈希须使用真实值）：

```json
{
  "schemaVersion": 1,
  "platform": "android",
  "version": "1.2.9",
  "buildNumber": 16,
  "fileName": "sxloc-android.apk",
  "size": 123456,
  "sha256": "安装文件的64位十六进制SHA256"
}
```

两端校验仓库地址、平台、标签、版本、大小及 SHA-256。Android 原生入口再次校验包名、版本、最低系统要求及同签名。APK 下载至应用缓存，使用只读临时 URI 交给系统安装；授权安装来源后需再次点击安装。替换应用会断开蓝牙会话，需要重新连接。

**签名：** 当前 Android 测试版使用既有测试签名；自行构建者通常使用不同签名，不能直接覆盖。正式版应由维护者独立管理稳定签名，不提交签名文件和密码。切换签名可能需要卸载测试版，先保留本机配置。

Windows 检查完整 ZIP 和版本，在应用目录旁暂存，更新助手等待界面和核心退出后将旧目录改名备份，再替换并启动。异常时尝试恢复旧版，不自动删除备份；应用目录必须可写。配置仍位于 `%LOCALAPPDATA%/SuixingLoc`。SHA-256 是完整性校验，其信任来源为 GitHub 仓库和 HTTPS；Windows 当前没有 Authenticode 发布者签名。真实覆盖、文件占用及失败恢复由维护者实测后确认。
