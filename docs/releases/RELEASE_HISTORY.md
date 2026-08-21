# 版本历史 / Release History

本仓库保留开发过程中的全部 Android 安装包。早期版本为调试 APK，文件较大且仅建议用于历史验证；从 `0.5alpha` 开始提供面向实际 Android 设备的 release APK。每一个 GitHub Release 都附有对应的 APK、可选 ZIP 包和 SHA-256 校验文件。

This repository preserves every Android build produced during development. Early builds are debug APKs and are primarily retained for historical verification; device-oriented release APKs are available from `0.5alpha`. Each GitHub Release includes its corresponding APK, optional ZIP bundle, and SHA-256 checksum where available.

| 版本 / Version | 阶段 / Milestone | 对应安装包 / Artifact | 说明 / Notes |
| --- | --- | --- | --- |
| [0.1alpha](0.1alpha.md) | 初始原型 / Initial prototype | `novel-notifier-debug.apk` | TXT 导入、基本分段与通知发送。 |
| [0.2alpha](0.2alpha.md) | 书籍主页 / Book home | `novel-notifier-book-menu-debug.apk` | 书本封面式主页、统一设置入口。 |
| [0.3alpha](0.3alpha.md) | 进度可视化 / Progress UI | `novel-notifier-progress-debug.apk` | 发送进度与暂停／继续反馈。 |
| [0.4alpha](0.4alpha.md) | 多书库 / Multi-library | `novel-notifier-multilibrary-debug.apk` | 多本 TXT、选书与会话隔离。 |
| [0.5alpha](0.5alpha.md) | 首个发布构建 / First release build | `novel-notifier-arm64-release.apk` | ARM64 release 与安装压缩包。 |
| [0.6alpha](0.6alpha.md) | 应用标识 / App identity | `wrist-novel-ritualcollapse-arm64-release.apk` | 中文名称与 `ritualcollapse` 包名。 |
| [0.7alpha](0.7alpha.md) | 稳定性修复 / Stability fixes | `wrist-novel-ritualcollapse-arm64-fixed-release.apk` | 发送与界面路径修复。 |
| [0.8alpha](0.8alpha.md) | 启动保护 / Startup guard | `wrist-novel-ritualcollapse-arm64-startup-guard.apk` | 书库异常恢复与空白页保护。 |
| [1.0](1.0.md) | 功能完整版本 / Feature-complete build | `wrist-novel-arm64-release.apk` | 网络 API 导入、自动保存、进度优化与测试通知。 |
| [1.1](1.1.md) | 原生通知权限 / Native notification permission | `wrist-novel-permission-onboarding-release.apk` | Android 权限桥接与强制引导授权。 |
| [1.2](1.2.md) | 图标与引导修复 / Icon & onboarding fixes | `wrist-novel-icon-onboarding-fix-release.apk` | 修复 `app_icon` 与授权状态竞态。 |
| [2.0](2.0.md) | 手环同步引导 / Wearable sync onboarding | `wrist-novel-wrist-manager-prompt-release.apk` | 最新版；增加手环管理软件通知镜像提示。 |

> 文件完整性 / Integrity: 对于提供 `.sha256` 或 `SHA256SUMS*.txt` 的版本，请在安装前校验下载的 APK。 For releases with `.sha256` or `SHA256SUMS*.txt`, verify the downloaded APK before installation.
