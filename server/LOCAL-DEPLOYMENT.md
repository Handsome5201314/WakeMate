# WakeMate 本地服务端与管理工作台

本目录提供 FastAPI 服务、PostgreSQL 持久化、提醒 Worker、只读 MCP 接入和管理后台。管理后台直接由 FastAPI 提供 HTML、CSS、JavaScript；没有前端构建步骤，也没有 Mock 数据回退。小智 MCP 接入可直接在后台配置，由独立的 `mcp-manager` 管理出站连接。

2026-10-12 已新增 [公网 HTTPS 后台](https://wakemate.tongyimoheai.top/admin)。本机 Docker 通过独立 SSH 隧道及新 Caddy 站点反代，维护方式见 [公网部署说明](PUBLIC-DEPLOYMENT.md)。

## 本地启动

前提是 Docker Desktop 已启动，Docker Compose 可用。以下命令的工作目录均为 `05-App与云端/wakemate-local`。

```powershell
.\tools\Start-WakeMate.ps1 -Build
```

首次启动会在智能药盒项目根目录 `.env` 中补齐尚未配置的数据库密码、签名密钥、管理员密码及端口，并依次启动数据库、执行迁移、初始化管理员、启动 API、Worker 和 `mcp-manager`。已有值会保留。当前数据库迁移为 `0003`，新增 MCP 连接配置表；升级前先执行备份。

默认入口：

| 入口 | 地址 |
| --- | --- |
| 管理工作台 | `http://127.0.0.1:8090/admin` |
| API 文档 | `http://127.0.0.1:8090/docs` |
| 进程健康检查 | `http://127.0.0.1:8090/health` |
| 数据库就绪检查 | `http://127.0.0.1:8090/health/ready` |

管理员用户名为 `admin`。密码读取项目根 `.env` 中的 `WAKEMATE_ADMIN_PASSWORD`，不要将密码写入本说明、源码或截图。

`.env` 相对路径取决于当前目录：从 `wakemate-local` 为 `../../.env`；从本文件所在的 `server` 为 `../../../.env`。启动脚本会自行定位，不需要手工复制环境文件。

查看容器状态：

```powershell
docker compose --env-file ../../.env ps
```

API 或静态页面修改后，用 `Start-WakeMate.ps1 -Build` 重新构建启动。普通停止使用：

```powershell
docker compose --env-file ../../.env stop
```

业务数据存储在 Compose 的 `wakemate-data` 数据卷中。停止容器不会清空数据。

数据库备份：

```powershell
.\tools\Backup-WakeMate.ps1
```

备份使用 PostgreSQL 自定义归档格式，先用 `pg_restore --list` 校验再复制到本地 `backups/`。该目录已排除 Git；备份可能包含个人资料和加密的 MCP 配置，应按私有数据保管。恢复时需先停止 API、Worker 与 `mcp-manager`，并明确选择归档及目标数据库；不要对未知目标执行覆盖恢复。MCP 配置解密依赖原 `WAKEMATE_SECRET`，恢复时应保留该密钥。

Docker Desktop 运行且电脑保持在线时，本地服务才可用；`restart: unless-stopped` 会在 Docker 重启后恢复容器，但不保证电脑关机或睡眠期间继续服务。

## 管理后台

登录使用 `POST /api/auth/password`。JWT 仅保存在当前浏览器标签页的 `sessionStorage`，API 请求携带 Bearer JWT；退出登录或认证过期时清除。页面与 API 使用同一来源，静态资源路径为 `/assets`。

| 视图 | 内容与操作 |
| --- | --- |
| 总览 | 患者、剂次、设备、失败提醒、MCP 绑定数量，以及 Worker 状态 |
| 患者与授权 | 患者和家属账户、新建账户、编辑患者显示名与时区、按患者查看授权状态与范围 |
| 用药计划 | 药名、剂量、每日时间、计划版本、设备同步和备注，只读 |
| 剂次与记录 | 当日剂次与近期证据；状态、证据、同步分别显示 |
| 设备 | 设备登记、患者归属、同步时间、固件与传感器核验状态 |
| 提醒 | 创建时间、下次尝试、实际送达、任务状态、失败原因和重试 |
| MCP 联调 | 创建患者、粘贴小智接入点、单患者绑定、连接状态、更新接入点、停止连接与撤销授权 |
| 审计日志 | 操作者、动作、对象、请求 ID 和明细 |
| 设置 | 实际环境、认证、提醒渠道、外部推送与 Worker 心跳 |

患者通常从 App 使用账号密码注册：`POST /api/auth/register` 创建 `patient` 并返回会话；之后 `POST /api/auth/password` 登录，后台下一次加载或刷新列表即可显示同一患者，无需短信或重复建户。后台仍保留手机号账户的人工新建入口，也可通过 `PUT /api/admin/users/{id}` 编辑患者显示名和时区；账号、手机号、角色只读。

管理员不会通过本界面替患者修改用药计划、确认服药或授予家属访问权限。家属选择身份不等于获得患者授权；有效授权必须经过服务端的邀请、接受与患者确认流程。

设备绑定码和设备凭证只在创建成功后展示一次。MCP 网页绑定使用隐藏输入接收小智 WSS 地址，保存后不回显，关闭窗口时清空输入；列表和审计不返回原始凭证。需要失效 MCP 授权时撤销对应绑定。

开盖是设备事件，不证明已经吞服；没有患者确认，也不能断言漏服。管理员证据接口可返回包含开盖等证据的近期剂次，即使该剂次仍处于待确认状态。`confirmation_receipt` 显示为“重复请求收据”，表示幂等重试的收据，不是新的服药事实。

## 第一版 Flutter App 的接入范围

患者 App 可使用本服务的登录、计划、剂次、确认、记录、统计、设置和设备相关 REST API。`GET /api/plans`、`GET /api/records`、`GET /api/records/stats`、`GET /api/device` 保留顶层数组；登录、确认和设置返回顶层对象，不能统一改成 `{data: ...}`。

### 患者注册与后台同步

App 主流程使用账号密码。以下仅说明请求格式，示例账户不预置到正式库：

```http
POST /api/auth/register
{"username":"example_patient","password":"example-only-password-2026","display_name":"患者称呼","timezone":"Asia/Shanghai"}

POST /api/auth/password
{"username":"example_patient","password":"example-only-password-2026"}
```

注册返回 `201` 和与密码登录一致的 `access_token/user_id/role/expires_in/token_type`；固定患者角色，不接受手机号、角色、状态等额外字段。账号为3–32位英文字母、数字或下划线，去前后空白并区分大小写；密码12–128位，不自动去空白；重复账户返回409。App 可用 `GET /api/auth/me` 获取资料，后台刷新后读取同一users表。后台资料编辑不改变患者ID、用药计划、授权或MCP绑定；纯账号账户不需要手机号，历史手机号账户继续只显示掩码。

接入时仍需核对以下差异：

- 账号密码注册/登录不依赖短信。旧OTP接口保留供运维联调，发送接口仍明确返回503，当前App主流程不调用它。
- 当前App首页读取 `/api/doses`，使用服务端稳定 `dose_instance_id` 和带时区的实际时间；确认带 `Idempotency-Key`，失败重试保持同一键，不根据手机本地时钟重造记录。App前台刷新剂次不等于后台系统推送已接通。
- App 的 `/api/records` 保留已确认服药记录语义；管理后台的 `/api/admin/patients/{id}/records` 用于追查近期证据，范围不同。
- App小醒页直接走小智官方OTA/语音连接，由后台MCP提供只读业务工具；旧 `/v1/chat/completions` 没有部署也没有被当前聊天页调用。设备认领UI和多设备清单已接通；商城、徽章、家属授权UI、通知收件箱UI和业务WebSocket尚未完成适配，FCM注册仍明确未配置。详见 [App当前适配边界](../flutter_app/README.md#当前适配边界)。
- 设备页用 `/api/device/bind` 的 `device_sn` 与24小时一次性 `claim_code` 认领管理员已登记设备；列表与MCP的 `get_device_status` 读取同一患者的醒伴设备，认领后未收到心跳显示“尚未上报”。手机或开发板绑定小智Agent不会自动登记为醒伴设备，当前不能确定正在讲话的具体终端。Wi-Fi开发板不需要蓝牙，本轮没有改固件或把小智在线状态映射为醒伴在线。
- 当前App默认服务地址为公网 `https://wakemate.tongyimoheai.top`，可通过 `--dart-define=WAKEMATE_BASE_URL=...` 覆盖。本机API仍只绑定电脑loopback；手机上的localhost指向手机自身。

## 提醒与外部推送

Worker 定期生成剂次并处理数据库中的提醒任务。未设置 `WAKEMATE_NOTIFICATION_WEBHOOK` 时，实际渠道为本地站内信 `inbox`，不发送微信、短信、FCM 或小智语音提醒。

配置外部投递需要同时提供真实可用的 webhook 和所需认证参数。后台分别显示创建时间、下次尝试及实际送达时间，并保留实际渠道和错误，失败任务可重试。站内信状态显示“站内信就绪”，其就绪时间独立标注，实际送达栏不将它表示成外部通知已送达。

## 小智 MCP

MCP 只提供以下五个只读工具：

| 工具 | 输入 |
| --- | --- |
| `get_today_doses` | 无 |
| `get_dose_status` | `dose_instance_id` |
| `get_recent_medication_history` | 可选 `days`，默认 7，范围 1–90 |
| `get_medication_plans` | 无 |
| `get_device_status` | 无 |

每份 MCP 凭证绑定一个患者。患者身份由服务端根据绑定推导，工具不接受任意患者 ID，也不提供 SQL、服药确认或计划写入工具。撤销绑定后，既有凭证不能继续访问患者数据。

按[小智官方接入说明](https://my.feishu.cn/wiki/HiPEwZ37XiitnwktX13cEM5KnSb)，小智 Agent 在通道内发起 `tools/list` 和 `tools/call`，醒伴执行工具并读取 PostgreSQL 数据。醒伴主动连接小智 WSS 是建立双向传输通道的方式，业务调用方向始终是“小智 Agent → 醒伴 MCP 工具 → 醒伴 API → PostgreSQL”。可复制的[小醒 Agent 提示词](../xiaoxing-system-prompt.md)已对齐上述五个只读工具。

接入托管小智优先使用后台的“MCP 联调”页：

1. 选择 App 注册产生的真实患者账户；刚完成注册时点后台“刷新”。后台仍保留“新建患者账户”作为辅助建档入口，不要用管理员或家属账户代替患者。
2. 在小智控制台打开该智能体的 MCP 扩展能力，复制完整的接入点地址。
3. 已有有效患者绑定时，在该行点“配置接入点”，粘贴完整地址后点“保存并连接”；无需重复新建授权。没有绑定时点“新建绑定”，选择患者并填写名称，再粘贴地址并保存。已有配置则使用“更新接入点”。
4. 点后台“刷新”查看传输状态、心跳、连接时间和最近工具调用。配置保存后由 `mcp-manager` 建立连接，暂时失败会重试并显示错误。
5. 刷新小智控制台，确认五个工具已出现，并由小智实际调用这些工具。`get_dose_status` 使用 `get_today_doses` 返回的真实剂次 ID；若患者还没有剂次，应先通过患者 App 建立真实用药计划，再验证该工具。

服务端仅接受官方 `wss://api.xiaozhi.me/mcp/` 接入点及其认证参数；HTTPS 后台地址或任意其他 WSS 地址不能替代它。完整 WSS 地址包含凭证，不要发到聊天、截图或日志里，也不要手工写入 `.env`。

连接配置及内部 API 凭证加密保存到 PostgreSQL。每个绑定对应一个患者，同一个接入点不能同时绑定多个患者。管理员应确保一个小智 Agent 只对应一个患者；服务端无法根据不同 token 自动证明它们是否属于同一个 Agent，App 注册也不会自动完成小智 Agent 绑定。后台可更新接入点；“停止连接”删除已保存的接入配置并轮转内部凭证，之后可重新配置；“撤销授权”使该绑定失效并删除接入配置。患者停用后，管理器也会停止其连接。

`mcp-manager` 默认随服务启动，即使没有绑定也应保持健康。它主动出站连接小智 WSS，再通过容器网络访问 WakeMate API；这个流程不要求把本机 API 暴露到公网。“传输已连接”只表示 WSS 连接建立，必须看到小智实际工具调用成功，才能确认外部接入可用。

本机 PowerShell 入口仍可使用：

```powershell
.\tools\Connect-Xiaozhi.ps1
```

也可明确选择患者：

```powershell
.\tools\Connect-Xiaozhi.ps1 -PatientId "患者账户 ID"
```

脚本验证真实患者后，以隐藏输入读取 WSS，并调用管理 API 将配置加密写入数据库，随后启动 `mcp-manager`；不再把接入地址写入项目根 `.env`。已有公网配置会自动合并保留。

检查连接状态：

```powershell
docker compose --env-file ../../.env ps mcp-manager
```

已部署公网隧道时，完整 Compose 状态命令见 [公网部署说明](PUBLIC-DEPLOYMENT.md)。历史 `xiaozhi` profile 中的单连接 `mcp-connector` 仍保留，新接入使用网页及 `mcp-manager`。

## 验证入口

服务端测试位于 `server/tests`。静态后台可使用以下命令检查 JavaScript 语法：

```powershell
node --check server/static/app.js
```

运行真实 PostgreSQL 测试与静态检查（测试会创建并清理独立随机 schema）：

```powershell
docker compose --env-file ../../.env exec -T api python -m pytest -q -p no:cacheprovider
docker compose --env-file ../../.env exec -T api ruff check app tests migrations --no-cache
```

2026-10-13 当前账号密码增量：服务端全量 **120 passed，47.12 秒**，新增22项注册测试，覆盖注册→登录→资料→后台同一患者ID、患者/MCP数据隔离、重复与并发、停用账户、额外角色字段拒绝、限流、密码边界及提交失败回滚。App主流程不依赖短信，默认使用公网来源；首页真实剂次幂等及账户/小智身份隔离代码已补齐。Flutter **29 passed、1 skipped**，`flutter analyze --no-fatal-infos` 为 0 errors/0 warnings/73 infos；真实 HTTP 契约 1/1 通过，包含真实注册、密码复登、剂次/幂等、记录统计/settings、后台同ID和跨患者404。公网最新镜像 API healthy，ready/admin/assets 200、未认证及错误密码 401、管理员登录 200，OpenAPI 已有 register/password/me/doses/confirm；正式库1管理员、0患者、0 MCP，QA schema 0。APK 已构建并校验 `output/apk/WakeMate-1.0.1+2.apk`（本地产物，未入库），使用 Android Debug 测试签名，尚未真机安装。数据库迁移仍为 `0003`，没有为本轮新增模型迁移。

2026-10-13 先前本机验收：98 项测试通过，使用真实 PostgreSQL 隔离 schema、HTTP、WebSocket 与官方 MCP SDK，覆盖连接配置加密、地址限制、患者隔离、更新与撤销、管理器锁和重试心跳、App 首次 OTP 建户、重复/失效 OTP、后台账户编辑与权限边界；`0003` 迁移已部署。Ruff 与 JavaScript 语法检查通过。MCP 与患者编辑网页流程通过 Playwright 验证，覆盖无患者引导、创建患者、地址错误、保存、更新、停止、撤销、输入清理以及桌面和 390px 手机布局。正式库未添加测试患者，API 与 `mcp-manager` 已部署且健康。截图及验证结果在仓库 `verification/`，详细范围见项目的“开发与验收-WakeMate本地服务端-20261012”记录。

本轮没有真实小智 WSS 凭证，因此未验证小智托管平台的真实连接与工具调用；后台的空配置健康状态不能作为外部接通的证据。

2026-10-13 后续只读核对：正式数据库与公网管理 API 均确认已有 1 个患者、1 条有效患者绑定，但已保存 WSS 配置仍为 0 条。此前“0 患者、0 MCP”是注册适配验收时的历史快照；当前未配置状态应通过已有绑定的“配置接入点”完成接入。本地与公网 `/assets/app.js` 与源码哈希一致，包含该操作；`mcp-manager` 健康。本次只修正 Agent 提示词及文档，未重部署或改变正式业务数据，真实小智调用仍待验证。

验收应覆盖账号密码注册与登录、管理员登录、无授权访问拒绝、计划与剂次区分、确认幂等、设备事件不自动确认服药、提醒重试、MCP 单患者隔离与撤销，以及桌面和移动视口中的空数据、加载和错误状态。外部推送、小智托管平台和实物药盒需要各自的端到端联调结果；短信仅属于保留的旧OTP运维接口，不是当前App注册的前置条件。
