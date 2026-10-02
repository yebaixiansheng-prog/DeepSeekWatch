# 官方 API 架构（v2 · 2026-09-30 推倒重来）

> 本文档描述**当前生效**的架构。
> v1（网页版逆向）的全部代码已删除，备份在 `legacy_backup/`（不进 git），
> 历史说明见文末「附录：为什么放弃 v1」。

---

## 1. 一句话

从「逆向 chat.deepseek.com 的私有协议」改为「调用 `api.deepseek.com` 官方开放平台」。

| | v1（网页版逆向） | v2（官方 API，当前） |
|---|---|---|
| 端点 | `chat.deepseek.com/api/v0/*` | `api.deepseek.com/chat/completions` |
| 鉴权 | 账号密码登录拿 token + **PoW 反爬** + 设备指纹 | **一个 API Key**（Bearer） |
| 反爬 | 必须算 PoW（`X-DS-PoW-Response`），删了直接 40301 | 无 |
| 风控 | `RISK_DEVICE_DETECTED`，`device_id` 必须持久化 | 无 |
| 流格式 | 私有 SSE 帧 + `message_id` 去重 + `stop_stream` | **标准 OpenAI SSE**，`data: {...}` / `data: [DONE]` |
| 鉴权失败 | **恒 HTTP 200**，只能看 body 里的 `code` | **明确的 HTTP 401/402/429** |
| 会话列表 | 服务端有（`chat_session/*`） | **无**，必须自己存 |
| 联网搜索 | 服务端内置 | **无**，用 function calling + 客户端抓取实现 |
| 代码量 | ~7000 行（含 412 行哈希 + C++ NAPI） | ~2000 行，**纯 ArkTS** |

**收益**：删掉了一整类「协议被改就失效」的脆弱逻辑（PoW 算法、帧格式、风控指纹），
从 7000 行降到约 2000 行，构建产物从 1.6MB 降到 195KB，且不再需要 C++ 原生模块。

---

## 2. 目录结构

```
entry/src/main/ets/
├── common/
│   ├── Constants.ets      ★ API 契约常量 + 内置密钥 + 错误码/文案
│   ├── RoundScreen.ets    圆屏几何（弦宽计算、字号档位）—— v1 沿用，与协议无关
│   ├── Crown.ets          表冠事件归一化 —— v1 沿用
│   └── Store.ets          Preferences 封装（含 getChecked 区分「没值」与「读失败」）—— v1 沿用
├── model/
│   ├── ApiClient.ets      ★ HTTP + SSE 解析 + 工具调用循环
│   ├── SearchService.ets  ★ Bing 抓取 + 解析（联网搜索的数据源）
│   ├── ChatStore.ets      ★ 本地会话存储 + 上下文裁剪 + 序列校验
│   └── AppConfig.ets      ★ 设置读写（密钥/模型/思考/搜索）
├── components/RoundWidgets.ets   圆屏组件（按钮/开关/分段）
└── pages/
    ├── Index.ets          启动页（直接跳对话页）
    ├── ChatPage.ets       ★ 对话主界面 + 设置面板
    └── SessionsPage.ets   历史会话列表
```

---

## 3. 协议要点（全部实测确认）

### 3.1 请求

```
POST https://api.deepseek.com/chat/completions
Authorization: Bearer <API_KEY>
Content-Type: application/json
```

请求体关键字段（`ApiClient.buildBody`）：

```jsonc
{
  "messages": [ {"role":"user","content":"..."} ],
  "model": "deepseek-flash",          // 或 deepseek-v4-pro
  "stream": true,
  "thinking": { "type": "disabled" }, // ★ 必须显式传，见 3.3
  "max_tokens": 4096,
  "tools": [ /* 仅开启联网搜索时 */ ],
  "tool_choice": "auto"
}
```

### 3.2 模型

| ID | 说明 |
|---|---|
| `deepseek-flash` | 默认。响应快 |
| `deepseek-v4-pro` | 能力更强 |

### 3.3 ★★ 最大的坑：`thinking` 省略 = 默认**开启**思考

实测（2026-09-30）：

```bash
# 不传 thinking，max_tokens=10
{"messages":[{"role":"user","content":"hi"}],"model":"deepseek-flash","max_tokens":10}
# → content: ""  ← 空的！
# → reasoning_content: "The user just said \"hi\". I should respond"
# → finish_reason: "length"  ← 10 个 token 全花在思考上
```

**手表场景下这是致命的**：用户会盯着一个空白的转圈等很久。
所以 `buildBody` **无条件**输出 `thinking` 字段，关闭时传 `{"type":"disabled"}`。

> 纪律：**任何依赖服务端默认值的字段，都必须显式传。**
> 默认值会变，而「省略」这个行为在代码里看不出来。

### 3.4 流式响应（标准 OpenAI 格式）

```
data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
data: {"choices":[{"index":0,"delta":{"content":"好的"},"finish_reason":null}]}
data: {"choices":[{"index":0,"delta":{"content":"，"},"finish_reason":null}]}
...
data: {"choices":[{"index":0,"delta":{"content":""},"finish_reason":"stop"}],"usage":{...}}
data: [DONE]
```

要点：
- 首帧 `delta` 里只有 `role`，`content` 是**空串**；
- 尾帧 `content` 也是空串，但 `finish_reason` 非 null，`usage` 挂在这一帧上；
- 思考模式下 `delta.reasoning_content` 先于 `delta.content` 到达；
- 结束标记是 `data: [DONE]`。

### 3.5 错误码（比 v1 好处理得多）

| HTTP | 含义 | 应用文案 |
|---|---|---|
| 401 / 403 | 密钥无效 | 「API 密钥无效，请在设置里重新填写」 |
| 402 | 余额不足 | 「账户余额不足，请先充值」 |
| 429 | 限流 | 「请求太频繁，请稍后再试」 |
| 5xx | 服务端故障 | 「DeepSeek 服务暂时不可用，请稍后重试」 |
| 0（网络层） | 不通/超时 | 「网络不通，请检查手表 Wi-Fi」 |
| 其它 4xx | 有 `error.message` 就用它 | 否则「请求失败（HTTP xxx）」 |

> 纪律：**这六种文案必须互不相同**。有专门的测试断言这一点
> （`tools/api-protocol-test.mjs` 的 `D 六种错误文案互不相同`），
> 因为「把两种错误写成一句话」是极易犯、又极难被用户说清的错。

---

## 4. ★ 联网搜索（function calling + 客户端抓取）

用户原话：「联网搜索功能，你看看能不能想一下办法做一下，实在不行就算了。」
结论：**能做，且不需要任何第三方 API 密钥。**

### 4.1 为什么不能直接搜

DeepSeek 官方 API **没有**内置联网搜索（v1 网页版有，但那是服务端能力）。

### 4.2 做法：把搜索实现成 function tool

```
① 请求带 tools 声明
      ↓
② 模型判断需要实时信息 → 返回 tool_calls
   {"name":"web_search","arguments":"{\"query\":\"今日科技新闻\"}"}
      ↓
③ 【客户端】抓 Bing 搜索结果页 → 解析出标题/链接/摘要
      ↓
④ 把结果作为 role:"tool" 消息追加，再请求一次
      ↓
⑤ 模型基于真实搜索结果作答
```

已实测跑通（`tools/live-e2e.mjs` 第 4 节），真实输出示例：

```
模型要搜: 今日科技新闻
取到 10 条，首条: 科技新闻_央视网 (cctv.com)
最终回答: 据 Readhub 每日早报（12小时前），今天的科技热点包括 OpenAI 因数据泄露解雇三名安全研究员…
```

### 4.3 搜索源选型（2026-09-30 实测）

| 源 | 结果 |
|---|---|
| DuckDuckGo（`lite.duckduckgo.com` / `api.duckduckgo.com`） | ❌ **直连超时**（HTTP 000，20s 无响应） |
| **Bing 中文站**（`cn.bing.com/search`） | ✅ **HTTP 200，97KB 真实结果页，`<li class="b_algo">` 结构稳定** |
| 百度 / 搜狗 | ⚠️ 可返回 200，但反爬更激进，未启用 |

### 4.4 解析的脆弱性（必须正视）

`parseBing` 依赖**第三方页面的 HTML 结构**，脆弱是本质的。因此：

- 解析失败的判据是「条目数为 0」，**不是抛异常**；
- 返回 0 条时，`formatForModel` 会生成一段**明确指示模型不要编造**的文本：
  ```
  【联网搜索：未找到"xxx"的结果】
  （搜索源未返回可用条目，可能被限流或改版。请如实告知用户你没能检索到实时信息，不要编造。）
  ```
- **搜索失败绝不允许升级成「整个回答失败」** —— 对话必须继续。

> 纪律：**「未配置」「网络失败」「搜到 0 条」是三种不同的状态，不许复用同一句话。**
> 对应地，`SearchService.search()` **永不抛异常**，失败也返回 `ok:false` 的结果对象。

### 4.5 轮数上限

`SearchConfig.MAX_ROUNDS = 2`：防止模型陷入「无限调工具」死循环。
超限时明确报错「模型请求联网搜索，但搜索不可用或已达上限」，而不是静默返回空回复。

---

## 5. ★ 上下文裁剪与序列校验

### 5.1 为什么要裁剪

官方 API 是**无状态**的：每次请求都要自带完整 `messages`。
手表上下文有限、网络慢，必须只发最近 N 条（`MAX_SEND_MSGS = 24`）。

**裁剪只影响发送，不删本地历史** —— 用户往回翻还能看到完整记录。

### 5.2 裁剪不能破坏的配对关系

官方 API 对消息序列有硬约束：

```
assistant(tool_calls=[c1])  ←→  tool(tool_call_id=c1)
```

一旦裁剪把配对切散（留下 tool 却切掉了它的 assistant），服务端只会回一个 400，
用户看到的是「莫名其妙失败」。

`trimForSend` 因此必须：
1. 保留第一条 `system`；
2. 起点若落在 `tool` 上 → **往前回溯**到发起它的 `assistant`；
3. 末尾若是「声明了 tool_calls 却缺结果」的 `assistant` → 裁掉。

### 5.3 `validateApiSequence`：结构不变量校验

除了裁剪，还提供**独立的校验器**，发送前跑一次：

```ts
const errs = validateApiSequence(apiList);
if (errs.length > 0) {
  // 明确告知 + 放弃本轮（不静默降级、不发出坏请求）
  this.errMsg = '对话上下文异常，请开启新对话';
  return;
}
```

校验的不变量：
- 首条不能是 `tool`；
- 每条 `tool` 必须能按 id 追溯到**前面**的 `assistant.tool_calls`；
- 每条 `assistant.tool_calls` 必须收到对应结果（末尾悬挂视为非法）；
- `tool` 消息必须有 `toolCallId`。

> ★ 这个校验器同时是**测试的断言依据**。
> 断言「结构不变量」比断言「某个具体下标的值」强得多：
> 前者能抓住整类 bug，后者只能抓住你恰好想到的那一个实例。

---

## 6. 本地会话存储

官方 API 无云端会话，历史全部本地存（Preferences）。

```
Keys.SESSION_INDEX  → 会话索引 JSON（id/title/createdAt/updatedAt/count）
session_<id>        → 单条会话的消息体 JSON
Keys.LAST_SESSION   → 最近打开的会话 id（冷启动恢复）
```

上限：单会话 200 条（`MAX_STORED_MSGS`）、最多 30 个会话（`MAX_SESSIONS`），
超出按「最久未更新」淘汰。

**索引损坏时的行为**：重置为空列表，而不是让应用崩掉 ——
用户最多丢列表（消息体仍在磁盘上）。

---

## 7. 离线验证体系

> 核心理念（来自 `skills/offline-regression-testing`）：
> **测试质量 = 交付质量**。手表上验证一轮要 3~5 分钟，
> 协议层的问题必须在 PC 上几秒钟验证完。

### 7.1 `tools/ets-load.mjs` —— 通用 .ets 加载器

把 `.ets` 机械剥离类型后当 ES module 跑，**不重写逻辑**。
这样测的是**真源码**，不是副本。

> 历史教训：曾「手抄」一份 PoW 算法来验证，抄错 5 处高低位顺序，
> 得出「工程算法有问题」的**错误结论**，白排查很久。

**内置安全网**：剥离后立刻做语法检查（`new Function`），
一旦非法就抛错并指出生成源码 —— **绝不把变异过的副本喂给测试**。

> ★ 剥离规则的两个坑（都真踩过）：
> 1. `extractBlock` 做括号配平时**必须先剔除注释**。本工程 JSDoc 里大量出现
>    `{ ... }`，不剔除会导致配平**提前结束**，函数只剩签名 ——
>    而**空函数体语法合法**，测试会在「函数永远返回 undefined」的情况下跑绿。
> 2. 判据不能写 `head.includes('=')` —— 函数签名里的**默认参数**
>    （`max: number = 24`）也会命中，会把整个函数体丢掉。

### 7.2 `tools/api-protocol-test.mjs` —— 协议层回归（116 项）

| 组 | 覆盖 |
|---|---|
| A | `SseDecoder` 分块边界（含**逐字节喂入**、CRLF、切在 `data:` 中间） |
| B | `SseChunk` 真实帧解析（首帧/正文帧/思考帧/尾帧/坏 JSON/`[DONE]`） |
| C | `ToolCallAccum` 参数分片拼接（真实形态：`{"que` + `ry": "` + `北` + `京天气"}`） |
| D | `ErrMapper` 错误分流 + **六种文案互不相同** |
| E | `trimForSend` / `validateApiSequence` 裁剪不产生非法序列 |
| F | `buildBody` 字段正确性（含「reasoning 不回传」「thinking 不能漏」） |
| G | `parseBing` 解析（用**真实抓取的 Bing 页面**做 fixture） |

真实数据样本：`tools/fixtures/bing_sample.html`（curl 实抓，10 条结果）。

### 7.3 `tools/mutate.py` —— 注入测试（★ 最重要）

```bash
python tools/mutate.py all      # 全部注入 → 跑测试 → 还原
python tools/mutate.py run 3    # 单条
```

**「从没红过的检查等于没有检查。」** 测试全绿可能是真的都对，
也可能是断言根本没覆盖到那条路径。唯一能区分两者的办法就是故意改坏。

10 个注入点，每个都对应一个**真实可能犯的错误**：

| # | 注入 | 对应的真实风险 |
|---|---|---|
| 0 | 删掉 `thinking` 字段 | 省略=开启思考，首字延迟极长 |
| 1 | SSE 不认 CRLF | 部分服务端用 `\r\n\r\n`，整条流解析不出来 |
| 2 | SSE 不做跨块缓冲 | HTTP 分块边界会切碎 JSON |
| 3 | 工具参数覆盖而非累加 | `arguments` 是分片下发的 |
| 4 | 鉴权失败复用网络文案 | 用户不知道该做什么 |
| 5 | `reasoning` 回传给 API | 官方 API 不接受，会 400 |
| 6 | 裁剪不回溯 tool 配对 | 产生孤立 tool → 400 |
| 7 | 裁剪不处理悬挂 tool_calls | 工具结果没回来就发出去 → 400 |
| 8 | 校验器对孤立 tool 视而不见 | 把校验器废掉 |
| 9 | 解析器不校验链接 | 把导航栏当成搜索结果 |

> ★★ **这套注入测试真的抓到了一个漏洞（2026-09-30）**：
> 注入 6 最初**未被捕获**。排查发现 `trimForSend` 的回溯分支
> **从没被执行过** —— 当时用例 `max=3` 的裁剪落点恰好是 `assistant`，
> 绕过了 `while (role === TOOL) start--`。
> 也就是说：**代码是对的，但「它对的证据」是假的**。
>
> 修法不是把 `max` 改对就完事，而是：
> ① 把校验逻辑抽成独立的 `validateApiSequence`；
> ② 测试改成断言**结构不变量**，并对**所有 max 取值**穷举验证（E7/E8）。
> 这样能抓住整类 bug，而不是某一个实例。

### 7.4 `tools/live-e2e.mjs` —— 真实 API 全链路（23 项）

用真源码的协议逻辑 + Node 的 fetch，打**真实 API**：

```bash
node tools/live-e2e.mjs
```

覆盖：非流式 / 流式 / 思考模式 / **联网搜索完整往返** / 错误密钥分流。

> 设计取舍：只有「socket」这一层换成 Node 的 fetch
>（`@ohos.net.http` 在 PC 上不存在），
> 协议逻辑**全部用真源码**。这样协议层行为与手表逐字节一致，
> 真机只需验证「UI 有没有把内容显示出来」。

---

## 8. 安全与发布

### 8.1 密钥是内置的

`Constants.ets` 的 `ApiKey.BUILTIN` 直接写了真实密钥（用户明确要求）。

**边界**：
- 该密钥**只能**用于个人自用构建产物；
- **绝不可**推到公开仓库 —— GitHub 上扫 `sk-` 前缀的爬虫是**分钟级**的，
  泄露后会被盗刷；
- `tools/desensitize.py` 在导出公开文档时做脱敏，
  但**代码文件本身不参与公开同步**。

### 8.2 如果要开源

必须先做：
1. 把 `ApiKey.BUILTIN` 改成空串，密钥改为运行时从设置页输入；
2. 或引入构建期注入（`build-profile` 里读环境变量）。

---

## 附录：为什么放弃 v1（网页版逆向）

v1 在技术上**是成功的** —— 它确实跑通了，包括：
PoW 计算（还写了 C++ NAPI 加速 190 倍）、私有 SSE 帧解析、
`message_id` 去重、`stop_stream` 清僵尸流、设备指纹持久化。

但它有三个**结构性**问题：

1. **脆弱**：依赖前端 bundle 的私有实现。上游改一个字段、换一次帧格式、
   加一道风控，整个应用就失效，且**没有官方文档可查**。
2. **复杂**：7000 行代码里，真正「聊天」的部分不到 1/5，
   其余全是在对抗反爬（PoW、指纹、UA、preempt 语义）。
3. **不可维护**：踩过的坑（`preempt` 必须 true、`message_id` 不能 static 去重、
   `device_id` 必须持久化…）全靠人肉积累，换个人接手几乎无法复现。

改用官方 API 后，这三条同时消失。

**保留 v1 备份的理由**：如果哪天官方 API 不可用，`legacy_backup/` 里是完整的
可回退实现（含 C++ 模块与全部测试）。它不进 git，只是本地保险。
