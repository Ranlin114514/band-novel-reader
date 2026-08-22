# 通知分段品牌预设 / Notification Segmentation Brand Presets

本应用按品牌自动设置的是**保守推荐分段字数**，而非对所有型号作出“硬件最大字符数”的绝对承诺。具体设备可能支持滚动查看、使用不同字符计算方式，或受手机通知栏预览长度限制；用户可以随时在统一设置中继续调整。

The app automatically applies a **conservative recommended segment length** for each brand. It is not an absolute hardware-character-limit claim for every model. Specific devices may support scrolling, count characters differently, or inherit the phone notification-preview limit; users can always adjust the value in Settings.

| 品牌 / Brand | 自动分段字数 / Auto segment length | 预设理由 / Preset rationale |
| --- | ---: | --- |
| 小米 / Xiaomi | 160 字 | Xiaomi Smart Band 10 官方上限为 200 characters；采用约 80% 的余量，以应对应用、标题、emoji 和通知栏差异。 |
| 华为 / HUAWEI | 80 字 | 官方说明不同型号通常为几十到一百多个汉字；80 位于该范围中段，并优先避免较小型号截断。 |
| 荣耀 / HONOR | 80 字 | 未公布统一上限；与华为类型设备一致，采用中等保守值。 |
| OPPO | 100 字 | 未公布统一上限；兼顾手环与可滚动通知的手表，使用中等保守值。 |
| vivo | 100 字 | 未公布统一上限；使用中等保守值，并允许用户按实际设备调低或调高。 |
| 其他品牌 / Other | 60 字 | 设备能力未知时采用最低的通用保守值，减少初次使用的截断概率。 |

> 预设作用于当前书籍的统一分段字数，并立即保存。若书籍已分段，应用会按当前书籍文本重新生成分段，发送进度将从开头开始；用户可先检查“预览分段”再开始发送。

## 证据与方法 / Evidence and method

小米官方 FAQ 明确给出 Xiaomi Smart Band 10 的 200-character 显示上限。华为官方说明不同手环／手表的单条消息显示上限通常在几十到一百多个汉字之间，且穿戴设备展示的是手机锁屏或通知栏预览内容。荣耀官方资料证实通知详情开关和熄屏表盘状态会影响可见内容，但未公布跨型号统一长度。OPPO 与 vivo 公开资料未给出可普遍适用的单条字符上限。因此，本表对没有公开固定上限的品牌使用可解释的保守预设，而非虚构精确容量。

## References

1. [Xiaomi Smart Band 10 FAQ](https://www.mi.com/global/support/faq/details/KA-579104/)
2. [华为：手环/手表连接手机，应用消息显示不全](https://consumer.huawei.com/cn/support/content/zh-cn16007895/)
3. [荣耀：手环/手表不显示微信、QQ和短信的具体内容怎么办？](https://www.honor.com/cn/support/content/zh-cn15820959/)
