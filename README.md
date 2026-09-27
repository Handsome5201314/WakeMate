# WakeMate 醒伴

> 伴醒同行 Wake Together

WakeMate 是一款把用药提醒、药珠硬件、小醒语音陪伴和家属协同放在一起的移动端产品。项目当前包含 Flutter Android 客户端、FastAPI 后端、WakeMate 视觉资产和小智官方 Server 接入层。

<p align="center">
  <img src="assets/wakemate_mark.svg" width="88" alt="WakeMate logo" />
  <img src="assets/xiaoxing_icon.svg" width="88" alt="小醒 icon" />
</p>

<p align="center">
  <img src="flutter_app/assets/images/xiaoxing_home.png" width="220" alt="WakeMate 首页小醒形象" />
  <img src="flutter_app/assets/images/wakemate_beads.png" width="220" alt="醒伴药珠" />
  <img src="flutter_app/assets/images/xiaoxing_chat.png" width="220" alt="小醒对话形象" />
</p>

## 产品亮点

- **醒伴药珠**：围绕用药计划、开合确认和剩余量，形成可追踪的提醒闭环。
- **小醒陪伴**：支持文字和语音对话，连接小智官方 OTA / WebSocket 会话。
- **家属协同**：记录服药状态，并为后端推送和异常提醒预留接口。
- **真实视觉资产**：蓝金 WakeMate 品牌、透明小醒 IP、药珠与商城商品素材已纳入 Flutter 客户端。
- **Mock 与真实后端双模式**：没有后端时可以运行 UI 演示，接入服务后不会把网络错误静默替换为成功。

## 项目结构

```text
WakeMate/
├── flutter_app/                  # Flutter Android 客户端
│   ├── lib/features/             # 首页、计划、统计、聊天、设备、商城、设置
│   ├── lib/core/xiaozhi/          # 小智 OTA、WebSocket、语音会话
│   ├── assets/images/             # 客户端实际使用的图片资产
│   └── test/                     # Flutter 测试
├── backend/                      # FastAPI 业务后端
├── assets/                       # 品牌和设计交付资产
├── docs/                         # 文档索引
└── *.md                          # 交付、架构和开发规范
```

## 快速开始

### Flutter 客户端

需要 Flutter 3.19+ 和 Android SDK：

```bash
cd flutter_app
flutter pub get
flutter run --dart-define=WAKEMATE_MOCK_MODE=true
```

Mock 模式可直接浏览首页、用药计划、数据统计、设备、商城和小醒对话流程。登录页使用开发模式验证码 `123456`。

### 连接真实后端

```bash
cd flutter_app
flutter run \
  --dart-define=WAKEMATE_MOCK_MODE=false \
  --dart-define=WAKEMATE_BASE_URL=http://10.0.2.2:8000
```

启动 FastAPI 后端所需的环境变量见 [`backend/.env.example`](backend/.env.example)。

### 小智官方 Server

客户端通过 OTA 获取 WebSocket 地址和 token：

```bash
flutter run \
  --dart-define=WAKEMATE_MOCK_MODE=false \
  --dart-define=XIAOZHI_OTA_URL=https://api.tenclass.net/xiaozhi/ota/
```

自部署服务只需要替换 OTA 地址。`78/xiaozhi-esp32` 是官方终端固件源码，不是客户端运行时 API 地址。完整配置说明见 [`flutter_app/README.md`](flutter_app/README.md)。

## Android APK

最新 Debug APK 在 GitHub Release 中提供：

**[下载 WakeMate v1.0.0 APK](https://github.com/Handsome5201314/WakeMate/releases/tag/v1.0.0)**

```text
SHA256: 60844114BA8C583F312F479AFB6EB669F613419EF34CC9E7CAA884256331C1B7
```

## 验证命令

```bash
cd flutter_app
flutter analyze
flutter test
flutter build apk --release
```

当前仓库不提交 `build/`、`.dart_tool/`、`.env` 和 APK 构建副本；APK 作为 GitHub Release 附件发布。

## 许可证与状态

这是 WakeMate 的产品原型和 Android MVP 工程。硬件 BLE、推送、生产数据库和正式账号体系需要按项目文档继续配置后再部署。
