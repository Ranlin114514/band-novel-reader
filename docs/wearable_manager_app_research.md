# 手环管理软件启动映射 / Wearable Companion Launch Mapping

## 已核验来源 / Verified sources

| 品牌 / Brand | 管理软件 / Companion app | Android 包标识 / Package ID | 依据 / Basis |
| --- | --- | --- | --- |
| 小米 / Xiaomi | Mi Fitness（Xiaomi Wear） | `com.xiaomi.wearable` | Google Play 页面标题为 “Mi Fitness (Xiaomi Wear)”，URL 明确使用该包标识。 |
| OPPO | OHealth（原 HeyTap Health） | `com.heytap.health.international` | Google Play 页面标题为 “OHealth”，正文说明其为 OPPO 智能穿戴设备配套应用，URL 明确使用该包标识。 |
| 荣耀 / HONOR | Honor Health | `com.hihonor.health` | Google Play 官方页面标题为 “Honor Health”，发布者为 Honor Device Co., Ltd.，页面说明该应用可连接和管理设备。 |
| 华为 / HUAWEI | HUAWEI Health | `com.huawei.health` | 华为官方页面将 HUAWEI Health 标记为智能生活控制中心，可管理穿戴设备；小米应用商店的官方分发页使用该包标识。 |
| vivo | Origin Health / 健康 | `com.vivo.exhealth` | Google Play 搜索结果将 Origin Health 标记为兼容手表的配套健康应用并使用该包标识。 |

## 实现策略 / Implementation strategy

Android 原生层通过 `PackageManager.getLaunchIntentForPackage()` 查找并启动选定品牌的管理软件。为了适配区域版本和旧版本，品牌映射将提供候选包标识列表，并按顺序尝试。若没有可启动的已安装应用，原生层将尝试以 `market://details?id=<package>` 打开应用商店；商店不可用时返回可读错误，Flutter 引导页提示用户手动安装或在手环管理软件中完成通知同步设置。

## 参考链接 / References

- Mi Fitness: https://play.google.com/store/apps/details?id=com.xiaomi.wearable
- OHealth: https://play.google.com/store/apps/details?id=com.heytap.health.international
- Honor Health: https://play.google.com/store/apps/details?id=com.hihonor.health
- HUAWEI Health: https://consumer.huawei.com/en/mobileservices/health/
