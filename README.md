# 随行定位 · sxloc

基于 Flutter 的全中文 iOS 定位工具，采用 macOS 风格界面，提供 Windows 桌面端与 Android 蓝牙端。

项目地址：[yfl520/sxloc](https://github.com/yfl520/sxloc)

## 下载与使用

当前提供测试预发布，实机效果及覆盖更新由用户验证后再发布正式版。

| 平台 | 当前测试版 | 下载 |
| --- | --- | --- |
| Windows x64 | 1.1.10（15） | [完整便携 ZIP](https://github.com/yfl520/sxloc/releases/tag/windows-v1.1.10%2B15) |
| Android 8 及以上 | 1.2.8（15） | [APK](https://github.com/yfl520/sxloc/releases/tag/android-v1.2.8%2B15) |

首次打开需主动同意[使用协议与免责声明](FlutterApp/assets/service_agreement.md)，协议更新后重新确认；关于页可再次查看。

**Windows：** 将 ZIP 完整解压，打开其中的 `随行定位/随行定位.exe`，保留旁边所有文件。使用蓝牙时，先在系统中与 iPhone 配对，再在应用中选择并连接设备。使用 USB 开发者通道时，需要 Apple Devices / iTunes 提供的设备服务，解锁并信任电脑；iOS 16 及以后需开启开发者模式。找不到开关时，可使用应用内“显示开发者模式入口”。iOS 17.0–17.3 的实现还需要手机与电脑位于同一局域网。USB 通道的系统适配范围不代表每个系统构建均已实测。

**Android：** 安装 APK，在系统蓝牙设置中与 iPhone 配对，打开应用并允许附近设备权限。在“设置 → 本机蓝牙地址”填入安卓手机自己的真实蓝牙 MAC 地址，不能填 iPhone 地址、Wi-Fi 地址或 `02:00:00:00:00:00`。返回首页选择 iPhone 并连接。等待认证与定位订阅；需要时在 iPhone 自带地图中请求当前位置。测试 APK 使用测试签名，自行构建的 APK 不一定能覆盖安装。

在地图上选点、搜索地点或输入 WGS-84 坐标后，点击“应用定位”或“应用并持续发送”。Windows 需先连接 iPhone 并完成认证，USB 通道需准备完成；未连接时会提示。连接前选好的坐标会保留，连接完成后手动应用。选点本身不发送新位置。结束时断开连接；停止发送不保证 iPhone 立即恢复真实位置。

## 功能与限制

- 地图选点、手动坐标、收藏、中文输入联想与地点搜索；地图、设备和收藏面板支持收起。
- 搜索支持高德和 Photon / OpenStreetMap。高德需在设置中填写自己的 **Web 服务 Key**。安卓 Key 和优先城市通过原生编辑窗口输入。
- 无坐标建议会继续补查地点详情、完整地址和地址编码；自动模式可补查其他地图数据。同名或近似结果需要核对，显示的匹配级别不等于门牌精度。数据未收录的地点可手动在地图选点。
- Windows 提供蓝牙 iAP2 和 USB 开发者定位；Android 使用经典蓝牙 iAP2，连接期间以前台服务维持会话。
- 显示认证、订阅、当前目标、发送状态与错误。“已提交 / 正在发送”表示本机链路状态，不能证明 iPhone 已采用目标位置。iOS 会融合不同定位来源，蓝牙连续换点仍可能受定位源选择影响。
- 关于页支持主动检查正式更新、查看说明、下载和发起安装。预发布不会作为正式更新推送。安卓安装需系统确认；Windows 替换目录前保留旧版备份。跨版本覆盖更新尚待实测。

地图和搜索需要联网，不能保证任意地名均有精确坐标。安卓不申请手机位置权限；Key 保存在本机。Windows 配置与收藏位于 `%LOCALAPPDATA%/SuixingLoc`，升级保留；加密配置不能直接跨 Windows 用户迁移。

## 源码与许可

构建环境、验证命令和发布约定见 [BUILDING.md](BUILDING.md)。Flutter 界面位于 `FlutterApp/`，Windows 定位组件位于 `Bridge/`，协议核心位于 `Protocol/`、`Engine/`、`Transport/`。旧版 WPF、CLI / Web 和 macOS 脚本保留，当前测试附件仅包含 Windows Flutter 与 Android 版。

本项目基于 [D1ngtalk/iap2loc](https://github.com/D1ngtalk/iap2loc) 修改，保留原项目版权并按 [GPL-3.0](LICENSE) 提供。实验身份来源及第三方组件署名见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。每个 Release 标签对应其修改源码，分发时应保留许可证、署名并提供对应源码。

独立私钥、证书、Android 签名、地图 Key、设备配对资料和个人配置不提交到仓库。测试二进制按原有设计内嵌公开实验身份，来源与重建方式见上述说明，不表示获得 Apple MFi 授权。仅用于自有或获授权设备的开发、研究与测试。
