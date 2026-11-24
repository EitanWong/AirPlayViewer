# Contributing

[简体中文](#简体中文)

## Code map

| Location | Responsibility |
| --- | --- |
| `Sources/AirPlayViewer/` | App entry point and resources. `Lifecycle/` owns app startup and identity; `Windows/` owns window controllers; `Mirroring/` owns the app-level session and renderer; `Settings/` owns preferences UI; `Localization/` owns string lookups. |
| `Sources/MirrorCore/` | Receiver, decoding, and stream policy, independent of the app UI. |
| `Sources/WindowLayout/` | Window geometry rules, separate from the controllers. |
| `Sources/CAirPlay/` | First-party C bridge in `vpv_*` and `include/`; `uxplay/` is vendored. |
| `Sources/CPlist/` | Vendored libplist and libcnary. |
| `Tests/` | Tests grouped by target; native test helpers live in `NativeMirrorTestSupport/`. |
| `App/`, `scripts/` | Bundle metadata and assets; build and maintenance commands. |

Keep experimental probes and internal reviews out of the public tree. The existing `Spikes/` and `Reviews/` directories are kept locally; move only reviewed, publishable material into `docs/`.

## Language and style

- Write identifiers, code comments, logs, and Conventional Commit messages in English. Use Swift API naming conventions and the checked-in editor settings. Keep unrelated formatting out of changes; never bulk-format vendored sources.
- Use English source copy with `en` and `zh-Hans` in `Localizable.xcstrings`. Use `L10n` for app strings and `App/<locale>.lproj/InfoPlist.strings` for OS prompts. Add translator context, preserve format arguments, and use the catalog's plural variants and locale-aware system formats. Follow the system language.
- Open feature PRs against `dev`. Before promoting `dev` to `main`, bump `VERSION` and run `sh scripts/ci.sh` to check repository files, run `swift test`, and verify the local DMG. Real-device mirroring, audio output, and language checks are part of the manual [release checklist](docs/release.md).

## 简体中文

- 代码按职责存放：`AirPlayViewer` 管应用界面和协调，`MirrorCore` 管接收和解码，`WindowLayout` 管窗口几何规则，`CAirPlay` 管 C 桥接，`CPlist` 和 `CAirPlay/uxplay` 存放第三方源码。测试按 SwiftPM target 分组。各目录见上表。
- 标识符、代码注释、日志和 Conventional Commit 消息用英文。遵循 Swift 命名规则和仓库编辑器配置，不做无关格式化，不对第三方源码跑全量格式化。
- 界面文案英文为源语言，至少维护 `en` 和 `zh-Hans`。应用文案放进字符串目录并通过 `L10n` 取值；系统权限说明放在 `App/<locale>.lproj/InfoPlist.strings`。保留参数、补翻译上下文，使用系统的复数、日期和数字格式，跟随系统语言。
- 功能 PR 合入 `dev`；从 `dev` 提 PR 到 `main` 前更新 `VERSION`，并运行 `sh scripts/ci.sh` 验证测试和 DMG。真机镜像、音频、语言切换与伪本地化按[发布清单](docs/release.md)验收。旧实验和内部评审保留在本地，不直接公开。
