# DeepSeek 手表版（HarmonyOS · 圆形表盘）

一个跑在**华为鸿蒙智能手表**上的 AI 对话客户端。纯原生 ArkTS/ArkUI 实现，
直连服务端 Web API，**不套壳、不内嵌网页、不经中转服务器**。

目标设备：HUAWEI WATCH 5（466×466 圆形屏，arm64-v8a，API 23）

---

## ⚠️ 关于本文档的脱敏

出于对上游服务的影响考虑，**文档中的真实域名、私有请求头前缀、真机调试 IP 已替换为占位符**
（`<API_HOST>` / `X-<PREFIX>-…` / `<DEVICE_IP>`）；接口路径、字段结构、错误码语义、协议帧形态
**保持原样** —— 那是本项目真正的工程价值。

源码 `entry/src/main/ets/common/Constants.ets` 中仍保留真实端点，
否则项目无法编译运行。请自行判断是否使用，并遵守服务商的使用条款。

## 免责声明

本项目仅供学习与技术交流。请勿用于商业用途、高频滥用或任何违反服务条款的场景。
作者不对使用本项目造成的任何后果负责。

---

## 核心特性

| 特性 | 说明 |
|---|---|
| 🔐 密码登录 | 只保留密码登录，无需验证码 UI；登录态用 Preferences 持久化，重启免登录 |
| 🗂 历史对话 | 右上角 `≡` 进入，可翻历史会话并切换上下文 |
| ⚡ 极速安全校验 | 服务端要求的 PoW 工作量证明，**用 C++ NAPI 原生模块实现**（详见下方） |
| 🧠 深度思考 / 🔍 联网搜索 | 右上角 `⋯` 设置，开关状态持久化 |
| 🎡 表冠交互 | 登录页调字号 / 对话页翻上下文（`onDigitalCrown`） |
| ⭕ 圆形表盘 | 全屏圆角裁切 + 圆方程逐行算宽，内容不被圆弧切掉 |
| 🔋 省电设计 | 单例 HTTP 连接、原生分片计算让出主线程、请求完成即释放 |

---

## 技术亮点

### 1. PoW 从 44 秒优化到 232 毫秒（190 倍）

服务端要求每次对话前完成一道工作量证明（难度 144000）。
**纯 ArkTS 实现的算力天花板只有约 1000~2000 次哈希/秒**，实测要 20~55 秒，
且 release 构建、多核并行、`Int32Array` 替换等常规优化**全部无效**
（其中 `Int32Array` 反而更慢）。

最终方案：**把哈希算法用 C++ 重写，通过 NAPI 暴露给 ArkTS**。

```
entry/src/main/cpp/
├── keccak_core.h / .cpp   # 算法实现（注意：只做 round 1..23，跳过 round 0）
├── napi_init.cpp          # 导出 hashHex / searchRange
├── CMakeLists.txt
└── types/libentry/        # 给 ArkTS 用的类型声明
```

关键设计：**真实向量自检 + 自动回退**。
`NativeHash.isOk()` 启动时用真实抓包数据验证 `hashHex` 与 `searchRange`，
任何异常或结果不符都自动回退到已验证的纯 ArkTS 实现 ——
**原生模块坏掉只会变慢，绝不会导致消息发不出去**。

调用侧还有两个细节：分片调用（每片 20000，避免长时间占住 JS 线程）、
片间 `await` 让出主线程。

### 2. 消息"发不出去"的真凶：ArkUI 的 ForEach 不重渲染

这个 bug 极隐蔽：日志显示内容**明明解析成功**
（`sse DONE frames=91 textLen=32`），但聊天气泡**永远是空的**。

根因是两件事叠加：

1. `@State` 只在**引用变化**时通知刷新 —— 原地改 `list[i].fragments` 等于什么都没发生；
2. `ForEach` 按 key 做 diff —— 流式助手消息的 id 固定（`a-xxx`），
   key 不变 ⇒ 判定"无需重绘"，日志里表现为 `AceForEach: ForEachNode skip mark dirty`。

**修法**：给消息加 `rev` 版本号，每次更新**构造新对象 + `rev++`**，
`ForEach` 的 key 改为 `m.id + '#' + m.rev`。

> 这是本项目最值得记住的坑。详见 `docs/交接文档_下一任AI.md`。

### 3. 鉴权失败时 HTTP 状态码是 200

实测：不带 token 返回 `200 {"code":40002}`，非法 token 返回 `200 {"code":40003}`，
被网关拦截返回 `200` + **一整个 HTML 页面**。

所以：
- **不能用 HTTP 状态码判断登录是否失效**，只能看响应体的 `code`；
- 解析层要区分"网络不通"（`-1`）与"响应不是 JSON"（`-2`），
  否则用户会在一个永远好不了的错误提示上反复重试。

### 4. 「聊两轮之后就再也发不出去」：`preempt` 的排队语义

这是本项目**最隐蔽**的一个 Bug：不报错、不超时、无日志，重新登录也不管用，
只有"多轮对话"才会出现 —— 单轮测试永远测不到。

根因是 `completion` 请求体里的 `preempt` 字段：

| 取值 | 服务端行为 |
|---|---|
| `false` | **排队**：该 session 上若还有未结束的流，新请求被挂进队列 —— **既不返回数据，也不报错** |
| `true` | **抢占**：先终止旧流再开始新一轮（官方 web 客户端的行为） |

早期写的是 `false`。只要有一轮没干净收尾（中途退出页面 / 掉网 / 息屏），
服务端就会留下一条**僵尸流**，之后每一轮都被排队挂死。
再叠加 `stop_stream` 调用时传了空 `message_id`（服务端直接忽略），
僵尸流源源不断。

**修法**：`preempt:true` + 从 SSE 首帧捞真实 `message_id` + 下一轮发送前主动停流。
另加**静默看门狗**兜底：45 秒零数据即判定挂起并给出可操作提示，
绝不让界面无限转圈。

### 5. 被风控判定为风险设备（而不是"网络被封"）

用代理/VPN 出口时 App 稳定报 `RISK_DEVICE_DETECTED`，
但**同一网络下浏览器访问 chat.deepseek.com 完全正常且登录态长期保持**。

结论：被拦的不是网络，是**请求不像正常客户端** ——
登录体缺 `device_name`/`device_model`/`platform`（web 客户端都会发，服务端据此给设备可信度评分），
UA 又自称 Mozilla/Safari 却没有版本号。浏览器没事是因为它有
**长期稳定的设备指纹 + Cookie 会话**，而 App 每次全新安装生成新的随机 `device_id`。

**修法**：补齐登录体设备字段、换成结构完整的浏览器 UA、
`device_id` 全链路持久化并作为 `x-ds-device-id` 请求头发送。

### 6. 圆形屏适配

- 最外层 `.borderRadius('50%').clip(true)`
- `RoundScreen.ets` 提供 `widthAtY()`（圆方程算某高度的可用宽度）、`wPct()`、`topInset`
- ⚠️ **466 屏 density=2 ⇒ 1vp = 2px**，算布局尺寸必须换算，否则必然溢出

---

## 快速开始

```bash
# 用 DevEco Studio (>= 5.0) 打开本目录
# 1. File > Open > 选择 DeepSeekWatch/
# 2. 配置签名（自动签名，需登录华为开发者账号）
# 3. Build > Build Hap(s)/APP(s) > Build Hap(s)
```

命令行构建（需已配置好 `signingConfigs`）：

```bash
./tools/build.sh           # release 构建
./tools/build.sh --full    # 被 safe-delete 拦截时用（全量重建）
```

> ⚠️ 工程根目录的 `hvigorw` / `hvigorw.bat` 是占位脚本，不能用。
> 且必须显式设置 `DEVECO_SDK_HOME`。`tools/build.sh` 已处理这些坑。

部署到手表（无线调试）：

```bash
./tools/d.sh tconn <DEVICE_IP>:45165
./tools/d.sh install -r entry/build/default/outputs/default/entry-default-signed.hap
```

---

## 目录速览

```
entry/src/main/
├── ets/
│   ├── pages/        页面：入口 / 登录 / 对话 / 历史
│   ├── components/   圆形表盘组件库（按钮 / 开关）
│   ├── model/        服务层：认证 / 对话 / SSE / PoW / HTTP / 原生哈希
│   └── common/       基础：常量 / 圆屏适配 / 表冠 / 哈希 / 存储
└── cpp/              C++ NAPI 原生加速模块
```

## 文档

- [鸿蒙手表应用开发 · AI 执行手册](docs/鸿蒙手表应用开发_AI执行手册.md) — **想自己做一个手表 App 就从这份开始**：面向 AI 的可执行手册，环境/构建/签名/真机调试全流程 + 圆屏几何 + 状态渲染坑 + 决策表 + 报错码处方
- [API 逆向规格](docs/API_SPEC.md) — 接口契约、SSE 帧形态、错误码（已脱敏）
- [交接文档](docs/交接文档_下一任AI.md) — **最全的一份**：17 个真实 Bug 的根因与修法、真机验证方法、已知坑
- [鸿蒙实战教程](docs/鸿蒙开发实战教程.md) — 圆屏适配、表冠、输入法等踩坑记录

## 调试工具（`tools/`）

| 脚本 | 用途 |
|---|---|
| `build.sh` | 一键 release 构建 |
| `d.sh` | hdc 直通（路径写死，避开引号/路径转换坑） |
| `w.sh` | 手表调试：`shot` / `tap` / `text` / `key` / `log` |
| `pow-verify.mjs` | PoW 全链路离线验证（**执行真源码**，8 项） |
| `sse-parser-test.mjs` | SSE patch 解析回归（9 项） |
| `live-e2e.mjs` | PC 端全链路验证（鉴权 → PoW → SSE → 历史回读 → **多轮连续对话**） |
| `desensitize.py` | 本文档的脱敏脚本 |

> ⚠️ 真机调试纪律：**每次点击前先截图确认当前屏幕**，不要盲点连续坐标；
> 不要用 `keyEvent Back` 收键盘（Back 会被路由消费掉，把页面整个弹走）。

---

## 许可

MIT License，详见 [LICENSE](LICENSE)。
