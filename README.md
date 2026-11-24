# AirPlayViewer

[简体中文](README.zh-Hans.md)

AirPlayViewer is a macOS menu-bar app that receives AirPlay screen mirroring and shows it in a floating window. It runs its own receiver on the local network.

## Install

When the first release is available, download the Arm64 DMG from the repository's **Releases** page, open it, and drag AirPlayViewer into **Applications**. The app requires Apple silicon and macOS 27 or later.

## Build and try it

Use an Apple silicon Mac running macOS 27 or later, with Xcode 27 or later selected as the active developer directory, and Homebrew.

```sh
brew install openssl@3 jq
sh scripts/make-app.sh
open build/AirPlayViewer.app
```

Allow Local Network access when prompted. On a sending device connected to the same local network, open Screen Mirroring and select the receiver name shown in AirPlayViewer. The menu-bar item opens the status window and receiver settings.

The app bundle built here is for local testing; it is not notarized.

## Development

- [Contributing and code layout](CONTRIBUTING.md)
- [Release checklist and CI setup](docs/release.md)
- [Third-party sources and licenses](ThirdParty/README.md)

Third-party code keeps its original licenses. The license for the project's own code still needs to be confirmed before publication.
