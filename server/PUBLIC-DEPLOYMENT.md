# WakeMate 公网部署与小智接入

2026-10-12 已部署并验证。业务服务和 PostgreSQL 继续运行在用户本机 Docker；阿里云提供 HTTPS 入口和独立反代。

| 入口 | 地址 |
| --- | --- |
| 管理后台 | https://wakemate.tongyimoheai.top/admin |
| 业务 API 前缀 | https://wakemate.tongyimoheai.top/api |
| API 文档 | https://wakemate.tongyimoheai.top/docs |
| 就绪检查 | https://wakemate.tongyimoheai.top/health/ready |
| 本机后台 | http://127.0.0.1:8090/admin |

管理员为 `admin`，密码读取智能药盒项目根 `.env` 的 `WAKEMATE_ADMIN_PASSWORD`。凭证不记录在文档或 URL 中。

## 实际路径

```text
浏览器 / App
  -> wakemate.tongyimoheai.top:443（Caddy，自动 HTTPS）
  -> 阿里云 127.0.0.1:18090（独立 SSH 反向隧道）
  -> 本机 wakemate-public-tunnel-1
  -> public-edge 网络 api:8000
  -> 本机 PostgreSQL
```

用户手工新增 A 记录 `wakemate` 指向云服务器公网 IP，服务器确认解析生效。HTTP 返回 308 到 HTTPS，Let's Encrypt 证书由 Caddy 自动管理。

`compose.public.yml` 增加独立网络 `172.30.90.0/29`，隧道地址 `.2`，API 地址 `.3`。API 仅信任 `172.30.90.2` 的代理头；Caddy 覆盖 X-Forwarded-For 为实际连接来源并删除客户端 Forwarded。云端 `18090` 和本机 `8090` 都仅监听 loopback，数据库没有公开宿主端口。

## 启动维护

以下命令在 `05-App与云端/wakemate-local` 执行：

```powershell
# 常规重建，保留已配置的公网隧道
.\tools\Start-WakeMate.ps1 -Build

# 单独配置 / 启动隧道
.\tools\Start-PublicTunnel.ps1

# 安装新增 Caddy 站点，验证旧路由后平滑加载
.\tools\Deploy-PublicProxy.ps1

# 公网资源、鉴权和真实登录检查，不打印凭证
python .\tools\Verify-PublicDeployment.py

docker compose --env-file ../../.env --env-file .public-deployment/tunnel.env -f compose.yml -f compose.public.yml ps
```

隧道脚本只读用户指定的 `E:/AI新青年/Dravet 夜间连续监护/.env` 中的 SSH 主机、用户名和私钥路径，没有修改此文件。私钥只读挂载，运行时副本位于 tmpfs，权限 600，没有复制进仓库或镜像。

`.public-deployment/tunnel.env` 只保存主机、用户名和挂载路径；`known_hosts` 只保存该主机已验证的公钥记录。目录已排除 Git。项目启动脚本及小智连接脚本会自动合并此配置，保留代理信任与专网；不要仅使用主 `compose.yml` 重建 API。

Docker Desktop 需运行，电脑需保持联网和唤醒。容器自动重启不能保证电脑关机、休眠期间公网可用。

## 原服务保护

远端新增 `/etc/caddy/wakemate.caddy`，主 Caddyfile 仅追加独立 import，原内容按字节保留。部署脚本在加载前后比较原域名路由，只规范化 Caddy 自动编号和配置隐藏路径；真实匹配、处理顺序或上游变化会被拒绝。新增保护逻辑有四项测试。

原文件备份使用 `/etc/caddy/Caddyfile.before-wakemate-<时间戳>` 命名，仅 root 可读。Caddy 平滑加载，进程未重启；Dravet 的 API、隧道、数据库和其他项目容器没有重启或修改，原 `.env` 哈希保持一致。

临时停止公网回源只需停止 `wakemate-public-tunnel-1`。正式撤除时，只移除本次 import 和新增站点，再验证 Caddy 并平滑加载；不要用整份旧备份覆盖后续配置。

## 小智 MCP

公网域名用于后台及 App REST。后台保存接入配置后，本机 `mcp-manager` 主动连接小智控制台提供的真实 WSS 接入点；此 HTTPS 域名不能替代该 WSS 地址。

[小智官方说明](https://my.feishu.cn/wiki/HiPEwZ37XiitnwktX13cEM5KnSb)要求使用该 WSS 通道承载本地 MCP 服务。通道建立后，由小智 Agent 发起 `tools/list` 和 `tools/call`，醒伴工具读取业务 API 和 PostgreSQL；这是小智调用醒伴数据。Agent 提示词见[小醒 System Prompt](../xiaoxing-system-prompt.md)，仅包含当前五个只读工具。

当前 App 默认业务来源为 `https://wakemate.tongyimoheai.top`，以账号密码注册/登录：`POST /api/auth/register` 创建患者并返回会话，`POST /api/auth/password` 登录已有账户；注册后后台刷新直接读取同一患者，无需短信或重复建户。设备认领和多设备清单已接通；最新适配范围见 [App 当前适配边界](../flutter_app/README.md#当前适配边界)。

1. 打开 [MCP 联调页](https://wakemate.tongyimoheai.top/admin#mcp)，选择 App 注册产生的真实患者账户；刚完成注册时点后台“刷新”。后台保留人工新建患者账户作为辅助入口。
2. 从小智控制台复制该智能体的完整 MCP WSS 接入点。
3. 已有有效绑定时，在该行点“配置接入点”，粘贴完整地址并“保存并连接”；已有配置时点“更新接入点”。没有绑定才点“新建绑定”，选择患者并填写名称后保存。
4. 点后台“刷新”检查真实连接状态、心跳及错误；刷新小智控制台确认五个工具出现，并实际调用工具查询患者数据。

只接受官方 `wss://api.xiaozhi.me/mcp/` 接入点及其认证参数。配置加密保存于本机 PostgreSQL，不写入 `.env`，保存后不回显完整地址。更新接入点会重建连接；停止连接删除配置并轮转内部凭证，撤销授权同时使绑定失效。完整地址含凭证，不要发到聊天或日志。

`mcp-manager` 默认启动，无绑定时也可健康；“传输已连接”仍需小智实际工具调用确认。五个只读工具、验证用的真实剂次 ID 和 PowerShell 隐藏输入兼容入口见 [本地部署说明](LOCAL-DEPLOYMENT.md)。本轮没有真实小智 WSS 凭证，外部小智接入仍待验证。

2026-10-13 后续正式库与公网管理 API 只读核对：1 个患者、1 条有效患者绑定、0 条已保存 WSS 配置，尚未接通小智；此前“0 患者、0 MCP”是先前验收快照。本地与公网 JavaScript 与源码哈希一致，包含“配置接入点”操作。当前浏览器会话过期，本轮未完成浏览器交互验收；未重部署、未修改正式绑定或连接。

## 验证记录

本轮账号密码增量：服务端全量 **120 passed，47.12 秒**，新增22项注册验证，覆盖注册后后台显示、患者与MCP隔离、重复/并发、停用、额外字段与权限、限流及提交失败回滚；使用隔离 PostgreSQL schema，不向正式库注入测试患者。Flutter **29 passed、1 skipped**；`flutter analyze --no-fatal-infos` 为 0 errors/0 warnings/73 infos；真实 HTTP 契约 1/1 通过。公网最新镜像 API healthy，ready/admin/assets 200、未认证及错误密码 401、管理员登录 200，OpenAPI 已有 register/password/me/doses/confirm；正式库1管理员、0患者、0 MCP。APK 已构建并登记（WakeMate-1.0.1+2，Android Debug 测试签名，尚未真机安装）。以下98项及公网部署记录属于先前已完成的验证，保留其原始范围。

- HTTPS 后台、CSS、JavaScript、Lucide 和就绪检查均返回 200；证书验证、HSTS、HTTP 跳转通过。
- 未认证管理员请求和错误密码返回 401；真实管理员登录及总览返回 200。
- 客户端伪造的两个来源 IP 未进入限流记录，来源由可信反代提供。
- 2026-10-13 先前 98 项真实 PostgreSQL / HTTP / MCP / WebSocket 回归通过，新增 App 首次有效 OTP 建户及后台患者编辑验证；测试数据使用隔离 schema。Ruff 通过，PowerShell、Shell、Compose 检查通过。`0003` 迁移已部署，正式库未添加测试患者；短信供应商仍未配置，CLI OTP 只用于运维联调。
- MCP 网页新建、更新、停止、撤销及桌面、手机布局通过 Playwright 验证；最新 API 与新增 `mcp-manager` 容器部署后健康，公网资源、鉴权与真实登录检查通过。
- 首次公网部署时，新建隧道重启后自动重新连接，公网健康检查恢复 200。本轮 MCP 更新没有重启原公网隧道或 Dravet 服务。
- 原三个域名路由一致；Dravet console 仍为 303、主站及 www 仍为 200，原服务进程与容器标识未变。
