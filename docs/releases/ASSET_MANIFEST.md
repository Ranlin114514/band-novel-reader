# 发布资源清单 / Release Asset Manifest

本清单将开发过程保留的安装包映射到 GitHub Release。所有 APK 均来自本项目的 `deliverables/` 目录；各发行页会同时上传相应 SHA-256 校验文件。早期调试 APK 的体积明显更大，仅用于保留完整开发历史；新安装建议优先使用最新 **2.0** 版本。

This manifest maps preserved development artifacts to GitHub Releases. All APKs originate from this project's `deliverables/` directory, and each release page will include a corresponding SHA-256 checksum. Early debug APKs are substantially larger and are retained only for a complete development history; new users should prefer the latest **2.0** release.

| 发行标签 / Release tag | 主 APK / Primary APK | 其他文件 / Additional files | 构建类型 / Build type |
| --- | --- | --- | --- |
| `v0.1alpha` | `novel-notifier-debug.apk` | `SHA256SUMS.txt` | Debug |
| `v0.2alpha` | `novel-notifier-book-menu-debug.apk` | `SHA256SUMS.txt` | Debug |
| `v0.3alpha` | `novel-notifier-progress-debug.apk` | `novel-notifier-install-package.zip`, `SHA256SUMS.txt` | Debug |
| `v0.4alpha` | `novel-notifier-multilibrary-debug.apk` | `novel-notifier-multilibrary-install-package.zip`, `SHA256SUMS.txt` | Debug |
| `v0.5alpha` | `novel-notifier-arm64-release.apk` | `novel-notifier-arm64-release.zip`, `SHA256SUMS-release.txt` | ARM64 release |
| `v0.6alpha` | `wrist-novel-ritualcollapse-arm64-release.apk` | `wrist-novel-ritualcollapse-arm64-release.zip`, `SHA256SUMS-wrist-novel.txt` | ARM64 release |
| `v0.7alpha` | `wrist-novel-ritualcollapse-arm64-fixed-release.apk` | `wrist-novel-ritualcollapse-arm64-fixed-release.zip`, `SHA256SUMS-fixed.txt` | ARM64 release |
| `v0.8alpha` | `wrist-novel-ritualcollapse-arm64-startup-guard.apk` | `wrist-novel-ritualcollapse-arm64-startup-guard.zip`, `SHA256SUMS-startup-guard.txt` | ARM64 release |
| `v1.0` | `wrist-novel-arm64-release.apk` | `wrist-novel-arm64-release.zip`, `wrist-novel-arm64-release.sha256` | ARM64 release |
| `v1.1` | `wrist-novel-permission-onboarding-release.apk` | `wrist-novel-permission-onboarding-release.zip`, `wrist-novel-permission-onboarding-release.sha256` | ARM64 release |
| `v1.2` | `wrist-novel-icon-onboarding-fix-release.apk` | `wrist-novel-icon-onboarding-fix-release.zip`, `wrist-novel-icon-onboarding-fix-release.sha256` | ARM64 release |
| `v2.0` | `band-novel-reader-2.0.apk` | `band-novel-reader-2.0.sha256` | ARM64 release |

> **安装建议 / Installation guidance**: 安装某个较旧版本前，通常需要先卸载较新版本，因为 Android 不允许将相同包名降级安装。 Before installing an older build, uninstall a newer build first in most cases because Android generally does not allow downgrading the same package ID.
