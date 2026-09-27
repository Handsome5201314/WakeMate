# assets/ — 图片资源说明

> 醒伴 WakeMate 原型 · 资源目录

---

## 本原型图片资源策略

本原型（投资人演示版）的页面效果图位于 `../图片/`；可复用的品牌与 IP 图形已从页面内联 SVG 提取到本目录：

| 资源类型 | 实现方式 | 说明 |
|----------|----------|------|
| 醒伴 WakeMate Logo | `wakemate_mark.svg` | 启动页产品标；白色版本 |
| 醒时科技标 | `wakeshift_mark.svg` | 公司署名与浅色背景 |
| 小醒 IP 头像 | `xiaoxing_icon.svg` | 灯罩头像基础矢量 |
| 小醒三姿态 | `xiaoxing_gentle.svg` / `xiaoxing_calm.svg` / `xiaoxing_soothe.svg` | 温柔提醒 / 轻声提示 / 安心安抚 |
| 小醒空状态插画 | `xiaoxing_empty_state.svg` | 无用药计划时的安心安抚图形 |
| 醒伴药珠图标 | `wakemate_beads_mark.svg` | 串珠弧线 + 主珠药仓 |
| 启动页背景 | `splash_bg.svg` | 原页面 CSS 渐变的可复用版本 |

---

## 设计规范高保真效果图（预留引用）

以下效果图位于 `../图片/` 目录，供视觉参考，不在原型中直接引用：

```
../图片/01_品牌进入页_启动与登录.png
../图片/02_首页.png
../图片/03_AI小醒对话页.png
../图片/04_用药方案页.png
../图片/05_硬件设备页.png
../图片/06_数据统计页.png
../图片/07_数据看板页.png
../图片/08_提醒浮层.png
../图片/09_空状态页.png
../图片/10_设置与关于页.png
../图片/11_组件库规范页.png
```

页面效果图仅作视觉参考，不作为应用运行时资源。可在对应页面添加：

```html
<img src="../图片/02_首页.png" alt="首页效果图" style="width:100%;border-radius:12px;">
```

---

## 未来资源扩展建议

如进入开发阶段，建议补充以下资源文件：

| 文件 | 用途 |
|------|------|
| `wakemate_mark.svg` | 醒伴产品标（APP 图标、导航栏） |
| `wakeshift_mark.svg` | 醒时科技公司标（关于页署名） |
| `xiaoxing_icon.svg` | 小醒头像矢量原件（动效底图） |
| `wakemate_beads_mark.svg` | 醒伴药珠硬件标识 |
| `splash_bg.svg` | 启动页背景（渐变矢量） |

以上文件名与 `醒伴_移动端UI设计规范与开发对接.html` § 09 开发对接清单保持一致。
