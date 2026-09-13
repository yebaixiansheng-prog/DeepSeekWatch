> ## ⚠️ 本文档已脱敏
>
> 为降低对上游服务的影响，文档中的**真实域名、请求头前缀、调试设备 IP** 已替换为占位符：
>
| 占位符 | 含义 |
|---|---|
| `<API_HOST>` | 对话服务的 API 域名 |
| `<STATIC_HOST>` | 前端静态资源域名 |
| `<PROVIDER_DOMAIN>` | 服务商主域名 |
| `X-<PREFIX>-...` | 私有请求头前缀 |
| `<DEVICE_IP>` | 真机调试用的设备内网 IP |
>
> 接口路径、字段结构、错误码语义、协议帧形态**均保持原样** —— 那是本项目真正的工程价值。
> 需要真实端点时，请自行抓包获取，并遵守服务商的使用条款。

# DeepSeek Web API 逆向规格（实测抓取于 2026-09-11）

> 来源：`https://<STATIC_HOST>/chat/static/main.5748b4eb39.js` 反混淆 + Playwright 实测

## 1. 域名与基础

| 项 | 值 |
|---|---|
| Web | `https://<API_HOST>` |
| 静态资源 | `https://<STATIC_HOST>` |
| API 前缀 | `/api/v0` |
| 鉴权 | `Authorization: Bearer <userToken.token>` |
| 设备标识 | `x-<prefix>-device-id` / `x-did` |

## 2. 登录（本项目只用密码登录）

### `POST /api/v0/users/login`

```json
{
  "email": "",
  "mobile": "191********",
  "password": "******",
  "area_code": "+86",
  "device_id": "<base64(随机80字节)>",
  "os": "web"
}
```

响应：

```json
{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{"user":{...},"token":"..."}}}
```

`biz_code` 错误码表（实测）：

| biz_code | biz_msg | 含义 |
|---|---|---|
| 0 | — | 成功 |
| 2 | `PASSWORD_OR_USER_NAME_IS_WRONG` | 账号或密码错误 |
| 11 | `RISK_DEVICE_DETECTED` | 风险设备（IP/指纹风控） |

### 关于人机验证（重要）

> ✅ **实测结论：密码登录全程不触发人机验证。**
>
> 抓包确认 `POST /api/v0/users/login` 直接返回 token，无任何验证码介入。
> 因此本项目 **只做密码登录**，手表端无需实现任何点选/滑块验证 UI。
>
> 备查：DeepSeek 官网使用的是**数美（Shumei）空间语义点选**验证码
> （`castatic.fengkongcloud.cn` / `mode-spatial_select`），
> **仅出现在「短信验证码登录」和「注册」流程**。若将来 DeepSeek 改动导致
> 密码登录也需要验证码，可参考以下契约重新对接：
>
> - DOM：`.shumei_captcha` → `.shumei_captcha_img_loaded_bg_wrapper img`
> - 提示：`.shumei_captcha_slide_tips`（例："点击图中最小的蓝色六棱柱"）
> - 全局钩子：`window.initSMCaptcha` / `window.SMCaptcha`

## 3. 用户设置

| 接口 | 说明 |
|---|---|
| `GET /api/v0/users/current` | 当前用户信息 |
| `POST /api/v0/users/update_settings` | 更新设置 |
| `GET /api/v0/users/settings` | 用户级设置 |

## 4. 会话管理

| 接口 | 说明 |
|---|---|
| `POST /api/v0/chat_session/create` | 新建会话 |
| `GET  /api/v0/chat_session/fetch_page` | 会话列表（**游标分页，走 URL query**） |
| `POST /api/v0/chat_session/update_title` | 改标题 |
| `POST /api/v0/chat_session/delete` | 删会话 |
| `GET  /api/v0/chat/history_messages?chat_session_id=` | 历史消息 |

### 4.1 会话列表 `GET /api/v0/chat_session/fetch_page`

> 2026-09-13 复测（bundle `main.d69e3d8c16.js`）：**这是 GET，不是 POST**，
> 游标走 URL query string。首屏（从最新往前翻）用 `lte_cursor.*`，
> 下拉刷新用 `gte_cursor.*`；`count` 为空时由服务端给默认页大小。

```
GET /api/v0/chat_session/fetch_page?lte_cursor.pinned=false&count=50
（可选：&lte_cursor.updated_at=<秒级时间戳>）
```

响应：

```json
{
  "code": 0,
  "data": {
    "biz_code": 0,
    "biz_data": {
      "chat_sessions": [
        { "id": "...", "title": "...", "title_type": "USER",
          "updated_at": 1789207417, "pinned": false, "model_type": "default" }
      ],
      "has_more": false
    }
  }
}
```

⚠️ `updated_at` 是**秒**（不是毫秒），展示前要 ×1000。


## 5. PoW 工作量证明（对话必需）

DeepSeek 自研哈希：**`wasm_deepseek_hash_v1`**（SHA3-256 变体，WASM 模块 `sha3_wasm_bg.7b9ca65ddd.wasm`）

### 5.1 取挑战 `POST /api/v0/chat/create_pow_challenge`

```json
{"target_path": "/api/v0/chat/completion"}
```

响应 `data.biz_data.challenge`：

```json
{
  "algorithm": "wasm_deepseek_hash_v1",
  "challenge": "<hex>",
  "salt": "<hex/str>",
  "difficulty": 144000,
  "expire_at": 1789063000000,
  "expire_after": 300000,
  "signature": "<hex>"
}
```

### 5.2 求解

对 `nonce` 从 0 递增，计算 `H(salt + "_" + nonce)`，直到哈希满足难度条件。
源码片段：`{challenge, salt, answer: nonce, signature, target_path}`

### 5.3 携带结果（**请求头**）

| 登录态 | Header | Value |
|---|---|---|
| 已登录 | `X-<PREFIX>-PoW-Response` | `base64(JSON.stringify({algorithm, challenge, salt, answer, signature, target_path}))` |
| 游客 | `X-<PREFIX>-Guest-PoW-Response` | `base64(JSON.stringify({salt, answer}))` |

## 6. 对话核心

### `POST /api/v0/chat/completion` — SSE 流式

请求体：

```json
{
  "chat_session_id": "<uuid, 新建时为空>",
  "parent_message_id": null,
  "prompt": "用户输入",
  "ref_file_ids": [],
  "thinking_enabled": true,
  "search_enabled": true,
  "preempt": false,
  "model_type": "default",
  "action": null
}
```

> `model_type`：`default`（快速模式）/ `expert`（专家模式）/ `vision`（识图模式）
> **实测账号 `expert` 与 `vision` 均为 `enabled:false, switchable:false`**，仅 `default` 可用。

### 6.4 SSE 事件流

| event | 含义 |
|---|---|
| `ready` | 连接就绪 |
| `update_session` | 会话 id / updated_at 回填 |
| `delta` | 增量内容（`data.value`） |
| `hint` | 状态提示 |
| `toast` | 服务端提示 |
| `finish` | 结束 |
| `close` | 关闭 |

### 6.5 正文增量帧的真实形态（2026-09-13 复测，**重点**）

> bundle 内解析器 `xQ` + 应用逻辑 `applyDeltaToMessage` 实测结论：
> **`o` 只可能是 `SET` / `BATCH` / `APPEND`；`p`（路径）与 `o` 都可省略，省略时沿用上一帧的值。**
> 多数正文增量帧**不带 `event:` 名**（没有 `event: delta` 这一层包装），
> 直接就是 `data: {...}`。

```
// 1) 首帧：整条助手消息，op=SET
data: {"p":"","o":"SET","v":{"response":{"message_id":2,"role":"ASSISTANT","status":"WIP",
       "fragments":[{"id":1,"type":"THINK","content":"","status":"WIP"},
                    {"id":2,"type":"RESPONSE","content":"","status":"WIP"}]}}}

// 2) 追加片段：类型只在这里出现！
data: {"p":"response/fragments","o":"APPEND","v":[{"id":1,"type":"THINK","content":"","status":"WIP"}]}

// 3) 正文增量：路径里只有索引，没有类型
data: {"p":"response/fragments/0/content","o":"APPEND","v":"用户"}
data: {"p":"response/fragments/1/content","o":"APPEND","v":"你好"}
data: {"p":"response/fragments/-1/content","o":"APPEND","v":"！"}   // -1 = 最后一个片段

// 4) 延续帧：省略 p/o，沿用上一帧
data: {"v":"想要"}

// 5) 服务端错误帧
data: {"code":40301,"msg":"INVALID_POW_RESPONSE"}
```

⚠️ **两个高发 bug 源**：
1. 只看路径前缀（`response/...`）会把 **THINK 的正文当成正文回答**渲染出来 ——
   必须像本工程一样维护「片段索引 → 类型」表，再按索引查类型。
2. 把「不带 `event:` 名的帧」当成可丢弃的 message —— 那恰恰是正文增量（Bug 5）。

消息模型：

```json
{
  "fragments": [ {"id":..,"type":"THINK","content":"..."}, {"id":..,"type":"RESPONSE","content":"..."} ],
  "has_pending_fragment": false,
  "conversation_mode": "...",
  "status": "..."
}
```


### 其他对话接口

| 接口 | 说明 |
|---|---|
| `POST /api/v0/chat/stop_stream` | 停止生成 |
| `POST /api/v0/chat/regenerate` | 重新生成 |
| `POST /api/v0/chat/continue` | 继续生成 |
| `POST /api/v0/chat/edit_message` | 编辑消息 |
| `POST /api/v0/chat/resume_stream` | 断线续传（配合 `x-ds-sse-heartbeat-timeout-secs`） |

## 7. 客户端设置

`GET /api/v0/client/settings?did=<uuid>&scope=<main|model|provider|web_upgrade|banner>`

`scope=model` 返回 `model_configs`：

```json
[{
  "model_type":"default","name":"快速模式","is_default":true,"enabled":true,"switchable":true,
  "welcome_msg":"使用快速模式开始对话",
  "input_character_limit":2621440
}]
```

> **注意**：官网当前已把"快速模式/专家模式"合并为一套 UI，`model_configs` 里 `expert` 已关闭。
> 本项目的手表端把"快速模式/专项模式"作为**手表本地交互分层**实现（映射同一 `model_type:default`，
> 差异体现在 `thinking_enabled` / `search_enabled` 默认值与提示词风格），以适配官网现状。

## 8. Fragment 类型与状态（实测枚举）

从 bundle 中提取到的完整类型集合（`_COLLAPSIBLE_TYPES` 等常量组）：

```js
RESPONSE_TYPES:      ["RESPONSE","TEMPLATE_RESPONSE"]
MAIN_RESPONSE_TYPES: ["RESPONSE"]
FILE_TYPES:          ["FILE"]
TOOL_TYPES:          ["TOOL_SEARCH","TOOL_OPEN","TOOL_FIND"]
COLLAPSIBLE_TYPES:   ["THINK","SEARCH","TOOL_SEARCH","TOOL_OPEN","TOOL_FIND"]
SEARCH_TYPES:        ["SEARCH","TOOL_SEARCH"]
TIP_TYPES:           ["TIP"]
THINK_TYPE:          "THINK"
READ_LINK_TYPE:      "READ_LINK"
```

⚠️ **容易踩的坑**：`SEARCH` 与 `TOOL_SEARCH` 是两个不同的类型——
- `SEARCH` 的 `content` 是**可读文本**（搜索素材整理阶段）
- `TOOL_SEARCH` 的 `content` 是**结构化数据**（`queries` / `results` 数组），不是纯文本

本项目把 `SEARCH` 归入 THINK 区展示，`TOOL_SEARCH`/`TOOL_OPEN`/`TOOL_FIND` 只显示状态徽标。

### 状态枚举

```js
MessageStatus: OK="FINISHED" | "WIP" | "INCOMPLETE"
               | "CONTENT_FILTER" | "CONTEXT_LENGTH_EXCEEDED" | "TIMEOUT"
搜索类额外:     "FAILED"
GenerateState: "INITIALIZING" | "AWAITING_FIRST_CHANGE" | ...
MessageRole:   "USER" | "ASSISTANT"     // 大写！
```

⚠️ **两个高发 bug 源**：
1. `MessageStatus.OK` 在序列化层是 **`"FINISHED"`** 而非 `"OK"`
2. `role` 是**大写** `USER`/`ASSISTANT`，按小写比较会导致气泡对齐全错

## 9. 历史消息的树形结构

`GET /api/v0/chat/history_messages?chat_session_id=<id>`

实测返回的 `chat_messages` 是**扁平数组**，靠 `parent_id` 串成树（支持重新生成产生的多分支），
**不是**天然的线性对话。

```json
{
  "code": 0,
  "data": {
    "biz_code": 0,
    "biz_data": {
      "chat_session": {...},
      "chat_messages": [
        { "message_id":"...", "parent_id":null,  "role":"USER",      "fragments":[...] },
        { "message_id":"...", "parent_id":"...", "role":"ASSISTANT", "fragments":[...] }
      ],
      "cache_control": "REPLACE" | "...",
      "cache_version": null,
      "cache_reset_at": null
    }
  }
}
```

**正确做法**：从没有子节点的末端沿 `parent_id` 回溯到根，反转后得到主链。
直接按数组顺序渲染会出现「顺序错乱 / 同一分支重复」。

> 客户端内部用 `url.split("?")[0]` 反推 path 做埋点，
> 证明查询参数确实拼在 **URL query string** 上（不是 POST body）。

## 10. 风控备注

沙箱（境外 IP）实测：

- 密码正确 → `RISK_DEVICE_DETECTED`(11)
- Playwright 提交时前端拦截，不发出请求

**结论**：登录/对话无法在沙箱内端到端跑通，属环境限制。代码按上述契约实现，需在真机（国内网络 + 手表）验证。

### 其他实测到的错误码

```js
MISSING_TOKEN / INVALID_TOKEN / USER_IS_BANNED
POW_HEADER_ERROR = 40300                      // PoW 头有问题
INVALID_POW_RESPONSE = 40301                  // PoW 结果不被接受
IP_ACCESS_RESTRICTED                          // IP 风控
MUTED                                         // 账号被禁言（data.end_at 为解禁时间戳）
```

#### ⚠️ 鉴权失败：HTTP 状态码永远是 200（2026-09-13 实测确认）

用探针脚本 `tools/probe-auth.mjs` 直接打 `fetch_page` 复测，结论如下：

| 场景 | HTTP 状态 | 响应体 |
| --- | --- | --- |
| 完全不带 `Authorization` | **200** | `{"code":40002,"msg":"Missing Token","data":null}` |
| 带 `Bearer INVALID_TOKEN` | **200** | `{"code":40003,"msg":"Authorization Failed (invalid token)","data":null}` |
| 请求未知路径 `/api/v0/__not_exist__` | **200** | **一整个 HTML 落地页**（不是 JSON） |

**三个必须知道的推论：**

1. **任何「用 HTTP status 判 401/403」的写法都不成立**，鉴权失败也是 200。
   判断登录是否失效只能看响应体的 `code`：
   - `40002` = 未携带 token
   - `40003` = token 失效（过期 / 被顶号 / 服务端注销）
2. **被网关或风控拦截时返回的是 HTML**，`JSON.parse` 会抛异常。
   如果把这个异常和真正的网络不通都归成「网络连接失败」，
   用户会在一个永远好不了的错误提示上反复重试。
   本工程在 `Http.parse()` 里把这两种情况分开：
   - `code = -1` (`LOCAL_NETWORK`) → 真·网络不通
   - `code = -2` (`LOCAL_BAD_PAYLOAD`) → HTTP 通了但响应不是 JSON
3. 上层据此给出**不同的**引导：40002/40003 → 「重新登录」入口；
   其余 → 「重试」。见 `ChatService.listSessions()` 的 `needRelogin` 字段。

> 40300 / 40301 多数不是算法错，而是**缓存的挑战已过期或被服务端作废** ——
> 正确做法是清掉本地 PoW 缓存、重新取挑战再发一次（本工程在 `ChatPage` 的
> `onError` 里做了「清缓存自动重试一次」）。

`POW_HEADER_ERROR` / `INVALID_POW_RESPONSE` 说明 PoW 头字段名或 base64 内容不对，
排查时优先检查 `X-<PREFIX>-PoW-Response` 的拼写与 JSON 字段完整性。


