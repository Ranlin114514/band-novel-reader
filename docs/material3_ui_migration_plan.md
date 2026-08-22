# Material Design 3 界面迁移计划

应用将继续保留 Flutter 作为跨平台实现框架，但视觉与交互规范统一采用 Material Design 3。迁移不改变小说导入、分段、通知发送、断点续传、品牌预设或后台恢复等业务行为。

| 优先级 | 区域 | Material Design 3 目标 |
|---|---|---|
| P0 | 全局主题与颜色 | 使用 `ColorScheme`、动态配色回退、语义化 surface/container 层级和 `ThemeData.useMaterial3`。 |
| P0 | 发送进度与任务状态 | 使用主题驱动的 `LinearProgressIndicator`、状态标签、按钮状态和辅助技术语义。 |
| P1 | 书库与设置 | 以 M3 `Card`、`ListTile`、`FilledButton`、`OutlinedButton`、`SegmentedButton` 和 `SwitchListTile` 替换手工视觉容器。 |
| P1 | 引导与品牌选择 | 使用可访问的选择卡片、语义化选中态和不遮挡品牌标识的状态反馈。 |
| P2 | 对话框、底部面板与提示 | 使用主题化 `DialogTheme`、`BottomSheetTheme` 和浮动 `SnackBar`，减少局部硬编码。 |
| P2 | 辅助页面 | 逐步将遗留 `BoxDecoration`、`ClipRRect` 与固定颜色迁移为 M3 色彩语义和标准组件状态。 |

所有后续 UI 改动必须通过 `flutter analyze`、现有单元测试和 Android release 构建；对品牌、后台任务或通知功能的改动必须保留当前持久化和恢复行为。
