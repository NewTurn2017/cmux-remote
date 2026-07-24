# cmux Remote 自建中转服务器

这个目录提供可自托管的 VPS Broker。使用它以后，Mac 和 iPhone 都只需
主动连接服务器，不需要在手机安装 Tailscale，也不需要给 Mac 开放入站端口。

```text
iPhone -- HTTPS/WSS --> VPS Broker <-- WSS -- Mac cmux-relay --> cmux Unix socket
```

默认的 Tailscale Direct 模式仍然保留。`relay.json` 的 `transport` 支持：

- `direct`：只启用原 Tailscale HTTP/WebSocket 服务，也是默认值。
- `broker`：只主动连接 VPS，不监听本机 `4399`，也不读取 Tailscale 身份。
- `both`：两种方式同时启用。

## 安全边界

- Caddy 自动签发公网 TLS 证书，iPhone 和 Mac 到 VPS 的链路都是 TLS。
- 手机 bearer token 在服务器磁盘上只保存 SHA-256，不保存明文。
- Mac 使用独立的 relay token；配对码只用于签发手机 token。
- 配对接口按来源 IP 限速，WebSocket 最大消息为 32 MB。
- **当前不是端到端加密。** VPS Broker 会转发明文终端帧，因此控制 VPS 的人
  理论上可以读取终端内容。只应部署在自己控制的服务器上。E2E 加密需要作为
  独立协议升级实现，不能把 TLS 等同于 E2E。
- Server 模式目前不代发 APNs。App 活跃且 WebSocket 在线时，Inbox 和本地
  通知正常；App 被系统彻底终止后不会由 VPS 补发通知。

## 1. 准备 VPS 与域名

需要一台带公网 IP 的 Linux VPS、Docker Compose，以及一个域名。把域名的
`A`（和可选的 `AAAA`）记录指向 VPS，并在防火墙放行 TCP `80/443` 与 UDP
`443`。Broker 容器本身不映射到公网，只有 Caddy 对外监听。

分别生成两个不同的随机值：

```bash
openssl rand -hex 32   # CMUX_RELAY_TOKEN
openssl rand -hex 32   # CMUX_PAIRING_CODE
```

不要让 relay token 与 pairing code 相同。

## 2. 启动 Broker

把仓库放到 VPS 后执行：

```bash
cd cmux-remote/broker
cp .env.example .env
chmod 600 .env
```

编辑 `.env`：

```dotenv
CMUX_BROKER_DOMAIN=relay.example.com
CMUX_RELAY_ID=home-mac
CMUX_RELAY_TOKEN=<第一个随机值>
CMUX_PAIRING_CODE=<第二个随机值>
```

启动并检查：

```bash
docker compose up -d --build
docker compose logs -f --tail=100
curl https://relay.example.com/v1/health
```

正常响应示例：

```json
{"ok":true,"relay_online":false,"version":"0.1.0"}
```

此时 `relay_online:false` 是正常的，表示 Mac 还没有连接。

## 3. 配置 Mac Relay

先从 **cmux 内的终端** 安装 relay：

```bash
cd cmux-remote
./scripts/install-launchd.sh
```

cmux 默认的 owner-only socket 模式会给内部终端注入一枚 capability。安装脚本
会把它保存到 `~/.cmuxremote/socket-control-capability`（权限 `600`），launchd
只保存该文件路径，不保存凭据本身。若日志出现 `only processes started inside
cmux can connect`，回到 cmux 终端重新运行安装脚本即可刷新 capability。

然后把 `~/.cmuxremote/relay.json` 改为下面的结构，也可参考
[`relay.example.json`](relay.example.json)：

```json
{
  "transport": "broker",
  "broker": {
    "url": "https://relay.example.com",
    "relay_id": "home-mac",
    "relay_token": "<与 VPS 的 CMUX_RELAY_TOKEN 完全相同>"
  },
  "default_fps": 15,
  "idle_fps": 5
}
```

保存后限制配置文件权限：

```bash
chmod 600 ~/.cmuxremote/relay.json
```

重启并查看日志：

```bash
launchctl kickstart -k "gui/$(id -u)/com.genie.cmuxremote"
tail -f ~/.cmuxremote/log/stderr.log
```

应看到 `broker transport enabled` 和 `connecting to broker`。再次访问健康接口时，
`relay_online` 应变为 `true`。

## 4. 配对 iPhone

在 App 的 Settings 中：

1. Connection Mode 选择 `SERVER`。
2. Server URL 填 `https://relay.example.com`。
3. Relay ID 填 `home-mac`。
4. Pairing Code 填 VPS 的 `CMUX_PAIRING_CODE`。
5. 点击 `SAVE & RECONNECT`。

第一次配对成功后，App 会把独立设备 token 存入 iOS Keychain，并清除本机
`UserDefaults` 中的 Pairing Code。修改 Server URL 或 Relay ID 时，旧 token 会
自动失效并要求重新配对。

## 设备管理

列出设备：

```bash
docker compose exec broker npm run devices -- list
```

撤销某台手机：

```bash
docker compose exec broker npm run devices -- revoke <device-id>
```

撤销后，已建立的连接最迟会在下次重连时失效。若怀疑 Mac relay token 泄露，
同时修改 VPS `.env` 和 Mac `relay.json` 中的值并重启两端。若只想禁止新手机
配对，修改 `CMUX_PAIRING_CODE` 并重启 Broker；已配对设备不受影响。

## 排查

| 现象 | 检查 |
|---|---|
| HTTPS 无法访问 | DNS 是否已生效，VPS 的 80/443 是否放行，查看 Caddy 日志 |
| `relay_online:false` | Mac 上 cmux 是否运行，`relay.json` 的 URL/ID/token 是否与 VPS 一致 |
| 手机 WebSocket 返回 503 | Mac relay 当前离线；先修复 Mac 到 Broker 的连接 |
| 配对返回 403 | Relay ID 或 Pairing Code 不一致 |
| App 显示 HTTPS 错误 | 公网 Server URL 必须使用受信任证书的 `https://` 地址 |
| 工作区为空或 RPC 报错 | 检查 Mac 的 cmux socket 与 `~/.cmuxremote/log/stderr.log` |

升级代码后，在 VPS 运行 `docker compose up -d --build`；在 Mac 重新运行
`./scripts/install-launchd.sh`，以确保服务使用新构建的二进制。
