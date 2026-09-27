# WakeMate Flutter APP

此目录包含醒伴移动端的 Flutter 页面、主题和 WakeMate API 客户端。

## 本地原型演示

当前交付包只包含 lib/ 和资源目录，没有 Flutter 自动生成的 Android/iOS 平台工程。需要在安装 Flutter 3.19+ 的环境中运行：

    flutter create .
    flutter pub get
    flutter run --dart-define=WAKEMATE_MOCK_MODE=true

Mock 模式会提供页面原型所需的计划、统计、设备和商城演示数据；登录手机号可填写任意 11 位号码，验证码为 123456。

## 真实后端

先启动 HANDOFF.md 中的 FastAPI 服务，再使用：

    flutter run --dart-define=WAKEMATE_MOCK_MODE=false --dart-define=WAKEMATE_BASE_URL=http://10.0.2.2:8000

真实模式不会把网络异常替换为 Mock 成功。计划、统计、商城和设置页面会显示错误并提供重试入口；计划保存后的 synced_to_hw 由后端返回。

## 小智官方 Server

聊天页会在进入时自动调用 OTA，随后使用 OTA 响应里的 WebSocket 地址和 token 建立官方终端连接。默认地址是小智托管服务：

    flutter run --dart-define=WAKEMATE_MOCK_MODE=false --dart-define=XIAOZHI_OTA_URL=https://api.tenclass.net/xiaozhi/ota/

自部署小智 Server 只需要把 `XIAOZHI_OTA_URL` 改为该服务的 OTA 地址，不需要单独填写 WebSocket 地址。若 OTA 返回 `activation`，页面会显示 6 位激活码并尝试用系统 TTS 播报；在控制台完成绑定后，客户端会自动轮询 `/activate`。

`https://github.com/78/xiaozhi-esp32` 是官方终端固件源码仓库，不是运行时 API 地址，不能直接填写到 `XIAOZHI_OTA_URL`。

小智 token 与 WakeMate JWT 是两套凭证。前者由 OTA 返回并只保存在本地运行时/偏好设置中，后者仍用于 WakeMate 业务 API。

正式 Android 构建前至少执行：

    flutter analyze
    flutter test
    flutter build apk --release --dart-define=WAKEMATE_MOCK_MODE=false --dart-define=WAKEMATE_BASE_URL=https://api.example.com
