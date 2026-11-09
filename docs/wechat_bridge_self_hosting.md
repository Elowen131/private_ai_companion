# 微信桥接 · 自部署联调步骤文档

> 目标：让用户可以在**自己的微信**里直接和「自己创建的角色」聊天，并把消息同步回 App 的加密会话。
> 本功能**仅走微信官方开放接口**（公众号消息接口被动回复 / 客服消息、企业微信自建应用消息回调 / 应用消息），
> 不读取、不拦截任何个人微信私有数据——**不是外挂式接管**。

---

## 0. 合规边界（务必先读）

| 项目 | 本方案 | 「外挂式接管」（违规） |
|---|---|---|
| 接口来源 | 微信官方开放平台 | 逆向 / 注入个人微信客户端 |
| 消息范围 | 仅「用户主动发给该公众号 / 应用」的消息 | 抓取用户全部私聊、群聊 |
| 账号要求 | 你**自己**拥有已认证的开发者账号 | 无账号、盗用他人 |
| 部署要求 | 你**自己**把桥接服务部署到公网 HTTPS | 第三方服务器暗中代管 |
| 数据归属 | 角色与记忆在你自己的 App 加密库 | 流经第三方、不可控 |

如果你没有已认证的微信开发者账号，本功能**无法启用**——这是微信平台的硬性前置条件，无法绕过。

两种接入模式共用同一套服务端代码，区别只在微信后台的配置入口：
- **微信公众号（订阅号 / 服务号）**：用「消息接口」被动回复 + 客服消息。
- **企业微信（自建应用）**：用「应用消息回调」+ 应用消息，需额外填 AgentId。

---

## 1. 部署架构

```
                        微信服务器 (官方接口)
                              │  HTTPS 回调
                              ▼
         ┌─────────────────────────────────────┐
         │   你的桥接服务 bin/wechat_bridge_     │
         │   server.dart  (公网 HTTPS, 已备案)   │
         │                                       │
         │  ① 校验 SHA1 签名 (token)             │
         │  ② 安全模式: AES-256-CBC 解密消息体   │
         │  ③ ChatOrchestrator 生成角色回复      │
         │  ④ 被动回复 / 客服消息 发回微信       │
         │  ⑤ AppPersonaChatPort 写回加密库会话  │  ← 与 App 共用同一份库
         └─────────────────────────────────────┘
                              │  BRIDGE_DB_PATH / BRIDGE_DB_KEY
                              ▼
                    App 加密 SQLite (角色 + 记忆 + 会话)
```

要点：桥接服务**直接读写 App 的同一份加密库**（通过环境变量指向相同路径与密钥），
所以微信里发生的每一句对话都会实时出现在 App 对应角色的会话里，反之亦然。

---

## 2. 前置条件清单

- [ ] 一台有**公网 IP / 域名**的服务器（或支持反代的家用宽带 + 动态域名），可用 HTTPS。
- [ ] 一个**已通过微信认证**的公众号（订阅号/服务号）**或**企业微信管理员权限（自建应用）。
- [ ] 服务器装好 **Dart SDK**（≥ 3.0，与本项目 Flutter 配套的 Dart 版本一致）。
- [ ] （可选，实现「同步回 App 同一份库」时需要）能把 App 的加密库文件与密钥安全传到该服务器，
      或者让桥接服务与 App 运行在**同一台机器**（桌面端 / 私有 NAS）。

> 仅做「微信能收到角色回复」的联调，不需要 App 库；要做「微信↔App 双向同步」，才需要指向同库。

---

## 3. 第一步：在 App 端完成配置

打开 App → 设置 → **微信同步（合规）**：

1. 打开「接入微信同步」总开关。
2. 填写字段（字段名与代码 `WeChatBridgeConfig` 一一对应）：
   - **公众号 AppID / 企业微信 CorpID** → `appId`
   - **回调签名令牌 Token** → `token`（与微信后台填的**完全一致**）
   - **消息加解密密钥 EncodingAESKey** → `encodingAesKey`（43 字符；**留空 = 明文模式**，仅做签名校验）
   - **AppSecret / CorpSecret** → `appSecret`（用于换取 access_token 发客服 / 应用消息）
   - （企业微信）**应用 AgentId** → `agentId`
   - **接入模式** → 公众号 / 企业微信
   - **绑定的角色** → 选一个你创建的角色（用户的发言会路由给这个角色）
   - **桥接服务公网地址** → `publicBaseUrl`，例如 `https://bot.example.com`
   - **回调路径** → `callbackPath`，默认 `/wechat`
3. 保存后，页面会显示「需要填到微信后台的回调地址」：`publicBaseUrl + callbackPath`
   （例如 `https://bot.example.com/wechat`）。**记下它。**
4. 点「本地连通自检」：用当前 token 模拟一次微信回声验证，确认签名逻辑正确（无需网络）。
   - 显示「自检通过」说明 token 已填写且本地签名一致；若失败，先确认 token 非空且一致。

> 所有凭据由 App 以**加密偏好**静态存储（密钥在系统安全存储），不落明文、不进日志、不进备份。

---

## 4. 第二步：准备服务端配置 JSON

在服务器上新建一个配置文件，字段与 `WeChatBridgeConfig` 相同（敏感字段与 App 端填的**完全一致**）：

```json
{
  "enabled": true,
  "mode": "officialAccount",
  "appId": "wxYourAppId",
  "token": "和App端填的Token一字不差",
  "encodingAesKey": "43位Base64密钥(留空则明文模式)",
  "appSecret": "你的AppSecret",
  "agentId": "",
  "personaId": "绑定的角色ID(与App端一致)",
  "publicBaseUrl": "https://bot.example.com",
  "callbackPath": "/wechat"
}
```

`personaId` 可在 App 的「角色管理」里查看该角色的真实 id（调试页 / 数据库均可查）。

---

## 5. 第三步：启动桥接服务

```bash
# 1) 进入项目根目录
cd /path/to/private_ai_companion

# 2) 启动（默认监听 8080，回调路径 /wechat）
dart run bin/wechat_bridge_server.dart /path/to/wechat_bridge_config.json

# 或：用环境变量指定配置文件路径
WECHAT_BRIDGE_CONFIG=/path/to/wechat_bridge_config.json dart run bin/wechat_bridge_server.dart
```

启动成功会打印：

```
微信桥接服务已启动: http://0.0.0.0:8080/wechat
请把上述回调地址（含路径）填到微信后台，并确保经公网 HTTPS 可达。
```

### 指向 App 同款加密库（实现双向同步）

```bash
BRIDGE_DB_PATH=/path/to/app/companion.db \
BRIDGE_DB_KEY=与App相同CipherKey \
dart run bin/wechat_bridge_server.dart /path/to/wechat_bridge_config.json
```

- `BRIDGE_DB_PATH`：App 加密库文件路径（桌面端通常在应用私有目录；移动端需先导出 / 同机运行）。
- `BRIDGE_DB_KEY`：库加密密钥（与 App 同源；**只在你信任的机器上配置**，切勿外泄）。
- 不设置这两个变量时，服务使用独立的 `companion_bridge.db`（仍可用，只是不与 App 共享记忆）。

### 改端口

```bash
BRIDGE_PORT=9000 dart run bin/wechat_bridge_server.dart config.json
```

---

## 6. 第四步：用反向代理做 HTTPS（关键）

微信后台**只接受 HTTPS 回调**。桥接服务本身是明文 HTTP，需要一层反代：

### Nginx 示例

```nginx
server {
    listen 443 ssl;
    server_name bot.example.com;

    ssl_certificate     /etc/ssl/bot/fullchain.pem;
    ssl_certificate_key /etc/ssl/bot/privkey.pem;

    location /wechat {
        proxy_pass http://127.0.0.1:8080/wechat;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        # 微信 GET 回声验证与 POST 消息体都不大，放宽到 1m 足够
        client_max_body_size 1m;
    }
}
```

Let's Encrypt 免费证书：`certbot --nginx -d bot.example.com`。

> 调试期可用 `ngrok http 8080` 之类临时隧道拿到临时 HTTPS 域名快速验证，正式上线请用自有域名 + 证书。

---

## 7. 第五步：在微信后台配置并启用

### 公众号路径
1. 微信公众平台 → **设置与开发 → 基本配置 → 服务器配置**。
2. URL 填：`https://bot.example.com/wechat`（即第 3 步记下的地址）。
3. Token 填：与 App / 服务端配置**完全一致**的字符串。
4. EncodingAESKey：点「随机生成」，把同一串同时填进 App 与服务端配置（若用明文模式则两端都留空）。
5. 消息加解密方式：选「安全模式（推荐）」或「明文模式」——**两端必须一致**。
6. 点「提交」，微信会立刻向你的 URL 发起 **GET 回声验证**（带 signature/timestamp/nonce/echostr）。
   服务端校验签名后原样返回 echostr 即验证通过。
7. 验证通过后点「启用」。
8. 如需主动发消息（客服消息），还需在「公众号 → 服务 → 客服」开启，且用户**48 小时内有过互动**才能下发。

### 企业微信路径
1. 企业微信管理后台 → **应用管理 → 自建 → 创建应用**，拿到 `AgentId`、`CorpID`、`Secret`。
2. 应用详情 → **接收消息 → 设置 API 接收**：
   - URL：`https://bot.example.com/wechat`
   - Token / EncodingAESKey：与配置一致。
3. 提交时同样会做 GET 回声验证。
4. 企业微信没有「48 小时」限制，应用可随时向成员推送应用消息。

---

## 8. 第六步：端到端联调验证

### 8.1 本地自检（无需真实微信）
App 内「本地连通自检」已覆盖签名 + 回声逻辑。

### 8.2 服务端回声验证（无需真实微信）
```bash
# 模拟微信 GET 验证请求
TOKEN="和配置一致的Token"
TS=$(date +%s)
NONCE="abc123"
SIG=$(printf '%s\n' "$TOKEN" "$TS" "$NONCE" | sort | tr -d '\n' | sha1sum | cut -d' ' -f1)
curl "https://bot.example.com/wechat?signature=$SIG&timestamp=$TS&nonce=$NONCE&echostr=hello_echo"
# 期望返回纯文本: hello_echo
```

### 8.3 真实发消息
在微信里给该公众号 / 应用发一条文字，例如「在吗」：
- 公众号：服务端收到 POST → 生成角色回复 → 以**被动回复**（5 秒内）或**客服消息**返回。
- 企业微信：以**应用消息**返回。
- 若已配置 `BRIDGE_DB_PATH/KEY`：打开 App，进入该角色会话，应能看到你刚发的微信消息 + 角色回复已落库。

### 8.4 安全模式（AES）联调
开启 EncodingAESKey 后，微信发来的 POST body 是密文。服务端会自动按
`AES-256-CBC`（key = Base64Decode(EncodingAESKey)，IV = key 前 16 字节）解密，
回复时再加密回包。可先用「明文模式」跑通全链路，确认无误后再切「安全模式」。

---

## 9. 请求 / 响应协议速查

| 微信动作 | 方法 | 路径 | 服务端行为 |
|---|---|---|---|
| 启用 / 验证 | GET | `/wechat?signature&timestamp&nonce&echostr` | 校验 SHA1 签名，原样返回 `echostr` |
| 用户发消息 | POST | `/wechat?signature&timestamp&nonce&msg_signature(安全模式)` | 验签 → 解密(安全模式) → 生成回复 → 加密(安全模式)回包 |
| 其它路径 | — | — | 404 |
| 签名不符 | — | — | 403 |

签名算法：`sha1( sort([token, timestamp, nonce]).join('') )` 后小写十六进制（与微信官方一致）。

---

## 10. 生产化建议

- **不要用 Mock 回复**：`bin/wechat_bridge_server.dart` 默认用 `MockLlmProvider` 便于零模型启动。
  生产请把 `buildBridgeService` 里的 `llm` 换成 `LocalLlmProvider`（端侧 GGUF，需服务器有算力）
  或你合规的云端 provider，并把 `BRIDGE_DB_PATH/KEY` 指向 App 库以实现同步。
- **跑成系统服务**：用 `systemd` / `supervisor` / `docker` 守护进程，崩溃自动重启。
- **日志脱敏**：切勿记录 message 明文与凭据；默认实现只记错误堆栈。
- **限流**：在反代层对同一微信 OpenID 做基础频率限制，防止单用户刷接口。
- **证书续期**：certbot 自动续期；或把 `BRIDGE_PORT` + 反代写进编排。
- **多角色**：当前配置以 `personaId` 绑定单一角色；如需「不同用户路由到不同角色」，
  可在服务端按微信 OpenID 做映射（扩展 `WeChatBridgeConfig` / `AppPersonaChatPort`）。

---

## 11. 常见问题

**Q：微信后台一直验证失败（echostr 不对）？**
- 确认 URL 路径与 `callbackPath` 一致（含前导 `/`）。
- 确认 Token 两端一字不差（注意首尾空格）。
- 用第 8.2 节的 curl 在服务器本地先验证签名逻辑（排除网络/反代问题）。

**Q：能收到消息但不回复？**
- 检查 `personaId` 在服务端配置里是否存在于库（指向 App 库时尤其注意 id 一致）。
- 公众号被动回复必须在 **5 秒**内返回；超时请改用客服消息（需用户 48h 内互动过）。
- 看服务端终端日志（会打印异常堆栈）。

**Q：安全模式报解密失败？**
- 确认 EncodingAESKey 两端（微信后台 / App / 服务端）完全一致，且为 43 字符 Base64。
- 先切回「明文模式」验证全链路，再切回安全模式。

**Q：微信里聊天能同步回 App 吗？**
- 只有配置了 `BRIDGE_DB_PATH` + `BRIDGE_DB_KEY` 指向 App **同一份加密库**时才会同步。
  否则微信侧可用，但不同步回 App 会话。

**Q：没有已认证账号能用吗？**
- 不能。这是微信平台的硬性要求，无法绕过，也不应绕过（否则即落入「外挂」违规区间）。
