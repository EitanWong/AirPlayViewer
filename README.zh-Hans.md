# AirPlayViewer

[English](README.md)

AirPlayViewer 是一款 macOS 菜单栏应用。它在局域网内运行自己的 AirPlay 接收器，并把收到的屏幕镜像显示在浮动窗口里。

## 安装

首版发布后，在仓库的 **Releases** 页面下载 Arm64 DMG，打开后把 AirPlayViewer 拖进「应用程序」。需要 Apple 芯片 Mac 和 macOS 27 或更新版本。

## 本地构建和试用

需要 Apple 芯片 Mac、macOS 27 或更新版本，以及 Homebrew。将 Xcode 27 或更新版本设为当前工具链。

```sh
brew install openssl@3 jq
sh scripts/make-app.sh
open build/AirPlayViewer.app
```

系统提示时允许访问本地网络。在连到同一局域网的发送设备上打开「屏幕镜像」，选择 AirPlayViewer 中显示的接收器名称。菜单栏图标可以打开状态窗口和接收器设置。

这样得到的应用仅用于本地测试，未经公证。

## 开发与发布

- [贡献规范与代码分层](CONTRIBUTING.md#简体中文)
- [发布清单与 CI 配置](docs/release.md)
- [第三方源码与许可证](ThirdParty/README.md)

第三方代码保留原许可证。项目自有代码的许可证仍待确认，暂不对外发布。
