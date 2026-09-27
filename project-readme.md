# 醒伴 WakeMate · 可交互概念原型

> 醒时科技 Wakeshift · 伴醒同行 Wake Together  
> v1.0.0-demo · 投资人演示版 · 2026-09

---

## 如何运行

**双击 `index.html`，在任意现代浏览器（Chrome / Safari / Edge）中直接打开即可。**

无需安装依赖、无需启动服务器、无需网络（ECharts 图表需要网络加载 CDN，离线时图表区域留空但其余功能正常）。

```
双击 index.html
    → 2 秒启动动画（自动跳转）
    → pages/home.html 首页
    → 通过底部 TabBar 导航各功能页
```

---

## 项目结构

```
醒伴移动端UI/
├─ index.html                   启动页（品牌进入动画，自动初始化演示数据）
├─ project-readme.md            本文件
├─ css/
│  └─ wakemate-tokens.css       完整 UI 设计 Token + 共享组件样式
│                               所有页面引入此文件，不在页面内硬编码色值
├─ pages/
│  ├─ home.html                 首页：倒计时主卡 + 数字工牌 + 快捷入口 + 提醒浮层
│  ├─ plan.html                 用药方案：计划列表 + 本周安排 + 添加/编辑表单
│  ├─ statistic.html            数据统计：ECharts 柱状/折线/环形，读取 localStorage
│  ├─ xiaoxing-chat.html        小醒 AI 对话：mock 智能体 + 打字动效 + 快捷回复
│  ├─ device.html               硬件设备：药珠刻度环 + 公仔灯光 + 手动模拟操作
│  └─ setting-about.html        设置 & 关于：家属推送 + 静默时段 + 品牌关于
├─ js/
│  ├─ mock-hardware.js          硬件模拟层（ESP32-S3 / RTC / 震动 / 电量）
│  ├─ mock-xiaozhi-server.js    调度层（WebSocket 桩 / 事件总线 / 漏服计时）
│  ├─ mock-agent-xiaoxing.js    小醒智能体（话术库 / 三姿态 / 场景路由）
│  └─ mock-mcp-tools.js         MCP 工具层（震动 / 家属推送 / 服药归档 / 统计）
└─ assets/
   └─ readme.md                 图片资源说明
```

---

## 完整交互流程

| 步骤 | 页面 | 操作 |
|------|------|------|
| 1 | `index.html` | 启动页自动初始化演示数据（localStorage），2 秒后跳转首页 |
| 2 | `home.html` | 首页展示倒计时（距最近服药时间），数字工牌实时刷新 |
| 3 | `plan.html` | 添加/编辑用药计划（药名/剂量/时间），保存至 localStorage |
| 4 | `home.html` | 点击「触发服药提醒演示」→ 弹出提醒浮层 + 模拟手表震动 |
| 5 | 提醒浮层 | 「已服用」→ 归档记录 + 家属推送 Toast + 工牌刷新 |
|   |          | 「稍后提醒」→ 30 秒后（演示模式）再次提醒 |
| 6 | `device.html` | 点击「模拟开盖」→ 药珠开盖事件经 mock-hardware → mock-xiaozhi-server 流转 |
| 7 | `xiaoxing-chat.html` | 与小醒对话；点击「我漏服了」触发安抚话术 |
| 8 | `statistic.html` | ECharts 从 localStorage 读取服药记录渲染三张图表 |
| 9 | `device.html` | 手动切换公仔灯光状态 → 状态同步至数字工牌 |
| 10 | `setting-about.html` | 开关家属推送、配置静默时段 |

---

## IS_MOCK_MODE 开关

每个 JS 文件顶部都有：

```javascript
const IS_MOCK_MODE = true;
```

**切换为生产模式的步骤（`IS_MOCK_MODE = false`）：**

### mock-hardware.js
- 将 `_startRTC()` 中的本地 `setInterval` 替换为订阅真实硬件 BLE/MQTT 事件
- 将 `simulateWristVibration()` 替换为真实手表震动 API（如 WearOS / watchOS Haptic）
- 将 `setBattery()` / `setBeadRemain()` 替换为从 ESP32-S3 固件读取的实时数据

### mock-xiaozhi-server.js
- 将 `connect()` 中的 `setTimeout` 替换为真实 WebSocket 连接：
  ```javascript
  const ws = new WebSocket('wss://your-xiaozhi-server.com/ws');
  ```
- 将 `send()` 替换为 `ws.send(JSON.stringify(event))`
- 将事件接收替换为 `ws.onmessage = (e) => dispatch(JSON.parse(e.data))`

### mock-agent-xiaoxing.js
- 将 `chat()` 中的本地话术库替换为调用小醒 AI 后端接口：
  ```javascript
  const resp = await fetch('/api/xiaoxing/chat', { method:'POST', body: JSON.stringify({ input, sessionType }) });
  ```

### mock-mcp-tools.js
- 将 `pushFamily()` 中的 Toast 替换为真实推送通道（APNs / FCM）调用
- 将 `archiveRecord()` 中的 localStorage 替换为后端数据库写入 API

---

## 原型边界说明

| 功能 | 原型状态 | 生产实现路径 |
|------|----------|-------------|
| 服药倒计时 | ✅ 本地 JS 计时，实时刷新 | 保持前端计时，配合硬件 RTC 校准 |
| 提醒浮层 + 震动 | ✅ CSS 动效模拟 | 接入系统推送通知 + 真实手表震动 API |
| 药珠开合检测 | ✅ 手动触发模拟 | ESP32-S3 磁吸传感器 → BLE 事件上报 |
| 小醒 AI 对话 | ✅ 本地话术库（20+ 条） | 接入小醒 AI 后端，支持多轮对话 |
| 数据统计图表 | ✅ ECharts + localStorage | 接入后端数据库，支持历史数据查询 |
| 家属推送 | ✅ Toast 模拟 | APNs / FCM 真实推送 |
| 硬件电量/余量 | ✅ 手动模拟 | BLE 实时同步硬件状态 |
| 用户登录 | ❌ 未实现 | 接入账号体系（手机号 / 微信授权） |
| 多用户（家属端） | ❌ 未实现 | 独立家属 App 或小程序 |

---

## 品牌规范摘要

- **公司**：醒时科技 Wakeshift（仅在关于页、启动页底部署名）
- **产品**：醒伴 WakeMate（所有用户可见品牌位）
- **AI 助手**：小醒（仅限聊天 Tab、空状态、提醒浮层、帮助场景）
- **硬件**：醒伴药珠（ESP32-S3，开合检测，不联网）
- **实体**：小醒潮玩公仔（灯光状态映射）
- **口号**：伴醒同行 Wake Together
- **禁止**：旧品牌名「睡眠药盒/SleepBox」、旧色 `#2E4A7C`、称重差分检测相关 UI

---

## MVP 红线指标（代码注释同步）

| 指标 | 目标 |
|------|------|
| 提醒触达率 | ≥ 95% |
| 服药确认率 | ≥ 85% |
| 家属推送打扰感 | ≤ 3/5 |
| 4 周用户留存 | ≥ 85% |

**头号风险**：推送通道稳定性（网络波动导致触达失败）

**MVP 不实现**：称重差分检测功能（代码中无任何相关逻辑）
