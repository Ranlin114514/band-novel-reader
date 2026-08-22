# 发布资源清单 / Release Asset Manifest

GitHub 的每一个发行页现在**仅保留一个 APK 安装包**，统一文件名为 `band-novel-reader.apk`。这样可以简化下载操作，并去除版本号后的横杆及描述性资产后缀。完整源代码、中英文更新日志和 GPL-3.0 许可仍保留在源码分支中。

Each GitHub Release page now retains **one APK installer only**, uniformly named `band-novel-reader.apk`. This simplifies downloading and removes hyphenated descriptive asset suffixes after the application name. Complete source code, bilingual changelogs, and the GPL-3.0 license remain on the source branch.

| 发行标签 / Release tag | 保留资产 / Retained asset | 构建类型 / Build type |
| --- | --- | --- |
| `v0.1alpha` | `band-novel-reader.apk` | Debug |
| `v0.2alpha` | `band-novel-reader.apk` | Debug |
| `v0.3alpha` | `band-novel-reader.apk` | Debug |
| `v0.4alpha` | `band-novel-reader.apk` | Debug |
| `v0.5alpha` | `band-novel-reader.apk` | ARM64 release |
| `v0.6alpha` | `band-novel-reader.apk` | ARM64 release |
| `v0.7alpha` | `band-novel-reader.apk` | ARM64 release |
| `v0.8alpha` | `band-novel-reader.apk` | ARM64 release |
| `v1.0` | `band-novel-reader.apk` | ARM64 release |
| `v1.1` | `band-novel-reader.apk` | ARM64 release |
| `v1.2` | `band-novel-reader.apk` | ARM64 release |
| `v2.0` | `band-novel-reader.apk` | ARM64 release; includes the Settings About section |
| `v2.1Alpha` | `band-novel-reader.apk` | ARM64 prerelease; adds wearable brand selection and companion-app launch |

> **安装建议 / Installation guidance**: 安装较旧版本前，通常需要先卸载较新版本，因为 Android 一般不允许为相同包名直接降级安装。 Before installing an older build, uninstall a newer build first in most cases because Android generally does not allow downgrading the same package ID.
