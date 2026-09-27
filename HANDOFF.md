# 醒伴 WakeMate · 开发交接文档

> 醒时科技 Wakeshift · v1.0-MVP · 2026-09  
> 交付给：研发小伙伴  
> 说明：本包已完成脱敏，所有占位符见下方「配置清单」

---

## 一、快速上手（5 分钟跑通演示）

> 最新系统架构和 APP 开发基线见：[wakemate-app-system-architecture.md](wakemate-app-system-architecture.md)。其中明确了 Flutter、小智官方 Agent、WakeMate 后端、MCP 和硬件的边界，以及当前交付包的协议缺口。

> 后端独立部署、多租户、数据权限隔离和 APP API 规范见：[wakemate-backend-development-spec.md](wakemate-backend-development-spec.md)。

### 1. 前端原型（无需任何配置，双击即可）

```
双击 index.html                  ← 前端原型入口
双击 wakemate-project-overview.html  ← 项目全景导航（建议先看这个）
双击 backend/admin/index.html    ← 运营管理后台（Mock 模式）
```

### 2. 后端 API

```bash
cd backend
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt

cp .env.example .env             # 填写 .env 中的占位符（见下方配置清单）

# 需要先启动 PostgreSQL 和 Redis。
# 当前交付包未包含 db-schema.sql/Alembic migration；正式建库脚本需要先补齐。
# 仅开发环境的 backend/db/database.py 会调用已导入模型的 create_all，不能作为生产迁移方案。

uvicorn main:app --reload --port 8000
# 访问 http://localhost:8000/docs 查看 API 文档
```

### 3. Flutter APP

```bash
cd flutter_app
flutter pub get
# 修改 lib/core/api/rest_client.dart 中的 kBaseUrl 为后端地址
flutter run                      # 连接 Android 设备或模拟器
```

### 4. ESP32 固件

```
Arduino IDE 安装依赖库：
  - ArduinoJson 6.21.x
  - Adafruit NeoPixel 1.12.x
  - ESP32 Board Package (Espressif) 2.0.14+

打开 esp32_clasp/clasp_firmware.ino
修改文件顶部三个占位符（见下方配置清单）
选板：ESP32C3 Dev Module → 上传
```

---

## 二、配置清单（占位符 → 真实值）

| 文件 | 占位符 | 说明 | 谁来填 |
|------|--------|------|--------|
| `backend/.env` | `your-xiaozhi-server.com` | 自部署 xiaozhi-server 域名/IP | 后端同学 |
| `backend/.env` | `your-secret-key-change-this` | JWT 签名密钥（随机 64 位字符串）| 后端同学 |
| `backend/.env` | `your-fcm-server-key` | Firebase FCM 推送密钥 | 后端同学 |
| `backend/.env` | `your-postgres-password` | PostgreSQL 密码 | 后端同学 |
| `esp32_clasp/clasp_firmware.ino` | `YOUR_WIFI_SSID` | 测试环境 Wi-Fi 名称 | 硬件同学 |
| `esp32_clasp/clasp_firmware.ino` | `YOUR_WIFI_PASS` | 测试环境 Wi-Fi 密码 | 硬件同学 |
| `esp32_clasp/clasp_firmware.ino` | `YOUR_BACKEND_IP` | 后端服务器 IP（局域网调试用）| 硬件同学 |
| `esp32_companion/companion_firmware.ino` | 同上三项 | 桌面摆件固件 | 硬件同学 |
| `flutter_app/lib/core/api/rest_client.dart` | `kBaseUrl` | 后端 API 地址 | Flutter 同学 |
| `flutter_app/lib/features/shop/shop_page.dart` | `business@your-company.com` | 企业采购联系邮箱 | 产品同学 |

---

## 三、项目结构速览

```
醒伴移动端UI/
├── index.html                      # 前端原型入口（双击运行）
├── wakemate-project-overview.html  # 项目全景交互导航（优先看）
├── HANDOFF.md                      # 本文档
├── wakemate-backend-development-spec.md  # 后端、多租户与 APP API 规范
├── db-schema.sql                   # 计划中的 PostgreSQL 建表 DDL（当前未交付）
├── pitch-narrative.md              # 投资人叙事文档
├── wakemate-mvp-tech-architecture.md  # 计划中的旧技术架构文档（当前未交付）
├── xiaoxing-system-prompt.md       # 小醒生产 System Prompt（可复制到小智 Server Agent）
│
├── css/wakemate-tokens.css         # 设计 Token（色彩/圆角/阴影/字号）
├── js/                             # 前端 Mock 四层架构
│   ├── mock-hardware.js            # 模拟 ESP32 硬件
│   ├── mock-xiaozhi-server.js      # 模拟 WebSocket 调度层
│   ├── mock-agent-xiaoxing.js      # 模拟小醒 AI 话术
│   └── mock-mcp-tools.js           # 模拟 MCP 工具执行
├── pages/                          # 前端 6 个页面
│
├── backend/                        # Python FastAPI 后端
│   ├── main.py                     # 入口
│   ├── .env.example                # 环境变量模板（复制为 .env 填写）
│   ├── requirements.txt            # 依赖（锁定版本）
│   ├── core/                       # 配置 + JWT 鉴权
│   ├── db/                         # PostgreSQL + Redis 连接
│   ├── models/schemas.py           # Pydantic 数据模型
│   ├── routers/                    # API 路由（auth/chat/plans/records/device/shop...）
│   ├── services/                   # 业务服务（AI调用/推送/MCP执行）
│   └── admin/index.html            # 运营管理后台（双击运行）
│
├── flutter_app/                    # Flutter Android APP
│   └── lib/
│       ├── main.dart               # 入口 + GoRouter + 5-Tab Shell
│       ├── core/                   # 主题/API/WS客户端
│       ├── features/               # 8 个功能页面
│       └── shared/widgets/         # 复用组件（小醒头像/数字工牌/提醒浮层）
│
├── esp32_clasp/                    # 智能扣头固件
│   ├── clasp_firmware.ino          # Arduino 固件
│   └── hardware-design.md          # 硬件方案（BOM/PCB/壳体/演示脚本）
└── esp32_companion/
    └── companion_firmware.ino      # 桌面摆件固件
```

---

## 四、Mock 模式 vs 真实模式切换

### 前端原型
```javascript
// js/mock-hardware.js 顶部
const IS_MOCK_MODE = true;   // false = 接真实 WebSocket
```

### Flutter APP
```dart
// lib/core/api/rest_client.dart
const bool kMockMode = true;  // false = 接真实后端
```

### 后端
```bash
# .env
XIAOZHI_MOCK_MODE=true   # false = 接真实 xiaozhi-server
```

### 管理后台
```
打开 backend/admin/index.html → 侧边栏「系统配置」
关闭「Mock 数据模式」开关，填写后端地址和 JWT Token
```

---

## 五、关键架构决策（开发前必读）

1. **药盒本体不联网**：用药计划固化 Flash（NVS），RTC 本地计时，断网 72h 依然能提醒。联网仅用于事件上报和时间校准。

2. **开合检测 ≠ 服药确认**：霍尔传感器只产生 `BEAD_OPEN` 辅助信号，正式确认必须用户在 APP 主动点击「已服用」。

3. **称重差分检测 MVP 不实现**：代码和 PCB 中无任何称重相关内容，不要添加。

4. **家属推送有约束**：必须经过静默时段检查（`check_quiet_hours=true`），日上限 5 条，priority=high 仅限电量<10% 或连续 3 次漏服。

5. **小醒话术红线**：漏服场景绝对不能指责用户，不给剂量调整建议，不诊断副作用。危机信号（自伤等）输出 `[CRISIS: true]` 标记，由上层处理。

---

## 六、MVP 硬性红线指标

| 指标 | 目标 | 说明 |
|------|------|------|
| 提醒触达率 | ≥ 95% | 三重保险：Wi-Fi上报 → WebSocket下行 → 本地预注册通知 |
| 服药确认率 | ≥ 85% | 小醒安抚话术 + 克制提醒风格 |
| 家属推送打扰感 | ≤ 3/5 | 静默时段 + 日上限 |
| 4 周用户留存 | ≥ 85% | AI 数据飞轮 + 硬件锚定 |

**头号风险**：推送通道稳定性（FCM/APNs 不稳定时触达率跌破 95%）

---

## 七、本地开发环境要求

| 工具 | 版本 | 用途 |
|------|------|------|
| Python | 3.11+ | 后端 |
| PostgreSQL | 16 | 主数据库 |
| Redis | 7 | 缓存/队列 |
| Flutter | 3.19+ | APP |
| Android SDK | API 31+ | APP 编译 |
| Arduino IDE | 2.x | ESP32 固件 |
| ESP32 Board Package | 2.0.14+ | Arduino 依赖 |

---

## 八、有问题？

1. 先看 `wakemate-project-overview.html`（双击打开），里面有完整架构图和 Demo 流程
2. 后端 API 文档：启动后访问 `http://localhost:8000/docs`
3. 硬件方案详见 `esp32_clasp/hardware-design.md`

---

*醒时科技 Wakeshift · 伴醒同行 Wake Together*
