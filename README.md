# 随行定位 · sxloc

基于 Flutter 的全中文 iOS 定位工具，采用 macOS 风格界面，提供 Windows 桌面端与 Android 蓝牙端。

项目地址：**https://github.com/yfl520/sxloc**

## 支持的功能

- Windows：蓝牙 iAP2 定位，以及 USB 开发者定位通道；USB 能力取决于设备系统、开发者模式和配对状态。
- Android：通过经典蓝牙连接已配对的 iPhone，完成 iAP2 协商、认证和定位订阅后持续发送坐标。
- 地图选点、坐标输入、收藏位置、中文地点联想与搜索；支持高德与 Photon / OpenStreetMap。
- 无坐标搜索建议继续解析地点详情和地址；自动模式可补查其他地图数据，仍可在地图上直接选点。
- 全中文界面，Android 使用“首页 / 设置”底栏，两端都有关于页及开源署名。

**目前为测试阶段。** Windows 桌面端与 Android 蓝牙端版本号独立；手机兼容性和最终定位效果由实机验证。iOS 会融合不同定位来源，蓝牙认证、订阅和发送成功不等于系统一定采用目标位置。地图数据不保证覆盖所有村庄、门牌或小地点。

## 使用与构建

- [Windows 桌面版](README-桌面版.md)
- [Android 蓝牙验证版](README-安卓蓝牙验证.md)
- [实验身份来源与重建方法](身份来源说明.md)
- [第三方组件说明](第三方组件说明.md)
- [上游 CLI / Web / macOS 文档](README-upstream.md)

Flutter 源码位于 `FlutterApp/`，Windows 定位组件位于 `Bridge/`，底层 iAP2 协议与传输实现位于 `Protocol/`、`Engine/`、`Transport/`。旧版 WPF、CLI 和 Web 实现保留用于来源追溯，当前桌面界面使用 Flutter。

依赖包括 Flutter、Windows 的 .NET 10 SDK / Visual Studio C++ 工具链，以及 Android 的 JDK 21 / Android SDK。版本及可配置路径见 `FlutterApp/pubspec.yaml` 和 `scripts/` 下构建脚本。Windows 原生构建需要英文路径的构建暂存目录。

```powershell
# 按来源文档恢复构建所需实验身份；材料不会提交到仓库
powershell -ExecutionPolicy Bypass -File scripts/import-desktop-identity.ps1

# Windows 测试目录；用本机安装路径替换参数
powershell -ExecutionPolicy Bypass -File scripts/publish-flutter.ps1 `
  -Flutter flutter -Dotnet dotnet -BuildRoot C:\SuixingLocBuild `
  -OutputRoot C:\SuixingLocTest -TestBuild

# Android 测试 APK；需按本机环境提供路径
powershell -ExecutionPolicy Bypass -File scripts/build-android-test.ps1 `
  -Flutter flutter -JavaHome C:\Java\jdk-21 -AndroidSdk C:\Android\Sdk `
  -BuildRoot C:\SuixingLocBuild -OutputRoot C:\SuixingLocAndroidTest
```

仓库只发布源码与构建说明。私钥、证书、Android 签名、设备配对资料、个人配置和地图服务 Key 均不提交。高德 Key 在应用设置中由使用者自行配置。

## 来源与许可证

本项目基于 [D1ngtalk/iap2loc](https://github.com/D1ngtalk/iap2loc) 修改，保留原项目版权及 [GPL-3.0 许可证](LICENSE)。相较上游，本项目主要增加 Flutter 中文界面、地图搜索解析、Android 蓝牙端与 Windows USB 通道。

实验身份重建参考 [DiPlay](https://github.com/shihabal3amri/DiPlay) 的公开版本；实现思路亦参考上游注明的 [WinPlay](https://github.com/Roylyl/WinPlay)。相关材料的来源和限制见[身份来源说明](身份来源说明.md)，不表示取得 Apple MFi 授权。

分发修改版或二进制时，请保留相应许可证、署名并提供对应源码。仅用于自有或获授权设备的开发、协议研究与测试。
