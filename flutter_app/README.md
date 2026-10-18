# WakeMate Flutter App

正式模式使用账号密码注册、登录，默认连接 `https://wakemate.tongyimoheai.top`。当前目录包含 Android 平台工程，干净 checkout 需按下文补齐未入库的 Gradle wrapper。业务服务端为仓库 `server/`，使用 Docker Compose 部署；历史 `backend/` 说明不能用于判断当前适配状态。

## 连接当前服务

在本目录执行，使用配置好的 Flutter 与 Android SDK：

```powershell
flutter pub get
flutter run --dart-define=WAKEMATE_MOCK_MODE=false --dart-define=WAKEMATE_BASE_URL=https://wakemate.tongyimoheai.top
```

登录页可以创建患者账号，或登录已有账号。账号为 3–32 位英文字母、数字或下划线，区分大小写；密码为 12–128 位。注册成功直接进入 App，后台刷新即可看到同一患者。正式登录入口不需要短信验证码。

如需调试本机 Docker 服务，Android 模拟器通过 `http://10.0.2.2:8090` 访问宿主；公网 HTTPS 地址适用于真机。`WAKEMATE_BASE_URL` 填写 API 来源，不带 `/admin` 或 `/api` 后缀。

## 检查与构建

本轮在独立 ASCII 路径副本构建，避免中文路径引发 Flutter 工具输出异常；未把生成工程覆盖到源目录。如副本缺 `android/gradlew.bat`，先在该副本根目录执行 `flutter create --platforms=android --project-name=wakemate --org=com.example --no-pub .` 补 wrapper，再配置 Android SDK/JDK17。构建使用 Flutter `C:/Users/lishuaishuai/Downloads/flutter/bin/flutter.bat`。

```powershell
flutter analyze --no-fatal-infos
flutter test
flutter build apk --release --build-name=1.0.1 --build-number=2 --dart-define=WAKEMATE_MOCK_MODE=false --dart-define=WAKEMATE_BASE_URL=https://wakemate.tongyimoheai.top
```

标准构建输出为 `build/app/outputs/flutter-apk/app-release.apk`。最新设备认领测试包保存在本机 `output/apk/WakeMate-device-claim-debug.apk`，使用 Android Debug 测试签名，不随源码入库；尚未进行真机安装或后台提醒验收。服务部署与 API 接入见 [本地部署说明](../server/LOCAL-DEPLOYMENT.md)。

## 小智 OTA 与患者 MCP

小智聊天端通过 OTA 获取 WebSocket 地址和会话凭证，默认 OTA 为 `https://api.tenclass.net/xiaozhi/ota/`。如需替换为已部署的 OTA，可增加构建参数：

```powershell
flutter run --dart-define=WAKEMATE_MOCK_MODE=false --dart-define=WAKEMATE_BASE_URL=https://wakemate.tongyimoheai.top --dart-define=XIAOZHI_OTA_URL=https://api.tenclass.net/xiaozhi/ota/
```

首次使用按页面激活码完成小智设备激活，并把该设备关联到目标 Agent。小智 device/client identity 按 WakeMate 患者账户区分；退出或切换账户后不应继续使用原患者会话。OTA 凭证与 WakeMate JWT 分开。

在 WakeMate 后台“MCP 联调”页选择同一患者，粘贴该 Agent 的官方 MCP WSS 接入点。App 设备所属 Agent 与后台患者绑定仍需人工对应；账号注册不会自动把小智 Agent 绑定到患者。完整说明见 [本地部署与接入](../server/LOCAL-DEPLOYMENT.md)。

## 当前适配边界

计划、真实剂次确认、记录统计、资料与提醒设置、设备认领及多设备清单已接入业务接口。设备页支持输入已登记设备的序列号和一次性绑定码，区分尚未上报、离线、在线和加载失败；首页和设置页展示多设备数量。账号密码注册、真实剂次幂等及患者/小智身份隔离已有实现和测试。

Wi-Fi 开发板无需通过 App 蓝牙配对。当前官方小智固件尚未接入醒伴心跳和药盒事件协议，小智平台绑定的设备不会自动出现在本清单中；开发板固件接入属于下一阶段。WakeMate MCP 提供患者名下的设备数据，当前通道无法可信识别正在讲话的具体小智终端。

商城和胸牌路由尚未在当前 `server/` 实现；通知收件箱、家属授权缺 App UI；FCM 和业务实时 WebSocket 尚未接通。真实模式直接展示错误，不把失败替换为假数据或成功。不能把所有原型页面视为已完整适配。

## 历史原型演示

仅在需要查看本地演示流程时使用：

```powershell
flutter run --dart-define=WAKEMATE_MOCK_MODE=true
```

Mock 构建可使用开发模式入口，其数据与会话不进入服务端。旧版“手机号 + 123456 验证码”和未生成平台工程的说明属于原型阶段；它们不再描述当前正式登录和构建流程。
