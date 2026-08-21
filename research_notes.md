# 扩展功能实现依据

## 后台持续发送

- `flutter_foreground_task` 11.0.1 用于 Android 前台服务，并支持重复任务与前台服务和 UI 之间的双向通信。
- 插件要求 Kotlin 2.2.20+、Gradle 8.11.1+。当前 Flutter 项目使用 Android Gradle Plugin 9.1.0、Kotlin 2.4.0，满足版本要求。
- 后台持续发送模式将通过 **Android 前台服务** 实现。需要声明 `FOREGROUND_SERVICE` 与 `FOREGROUND_SERVICE_DATA_SYNC` 权限，并声明插件指定的 `ForegroundService`，类型为 `dataSync`。
- Android 15 对 `dataSync` 类型前台服务有 24 小时内累计 6 小时的运行预算；因此应用会在界面中显示后台模式的用途与限制，并支持用户手动停止任务。

## TXT 小说导入

- `file_picker` 12.0.0 支持原生文件选择器、扩展名筛选和通过字节读取所选文件内容。
- 应用仅开放 `.txt` 格式导入，读取 UTF-8（优先）以及常见 UTF-16 编码文本；导入后将文本写入编辑区并立即重新分段。

## 参考

1. https://pub.dev/packages/flutter_foreground_task
2. https://pub.dev/packages/file_picker
3. https://developer.android.com/about/versions/14/changes/fgs-types-required
