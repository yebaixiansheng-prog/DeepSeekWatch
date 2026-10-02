# DeepSeek 手表版（HarmonyOS · 圆形表盘）

一个跑在**华为鸿蒙智能手表**上的 AI 对话客户端。纯原生 ArkTS/ArkUI 实现，
直连 **DeepSeek 官方开放平台 API**，**不套壳、不内嵌网页、不经中转服务器**。

目标设备：HUAWEI WATCH 5（466×466 圆形屏，arm64-v8a，API 23）

> **v2 说明（2026-09-30）**：本项目经历了一次**推倒重来**。
> 早期版本逆向 `chat.deepseek.com` 网页版私有协议（含 PoW 反爬、设备指纹、
> 私有 SSE 帧），代码约 7000 行、构建产物 1.6MB。
> 现改为调用官方 API：**约 2000 行、195KB、纯 ArkTS**（不再需要 C++ 原生模块）。
> 详见 [官方 API 架构 v2](docs/官方API架构_v2.md)。

## 免责声明

本项目仅供学习与技术交流。请勿用于商业用途、高频滥用或任何违反服务条款的场景。
作者不对使用本项目造成的任何后果负责。

> ⚠️ **API 密钥**：工程内 `Constants.ets` 的 `ApiKey.BUILTIN` 需要你填入自己的密钥。
> 仓库中**不含**任何真实密钥。请勿把自己的密钥提交到公开仓库 ——
> GitHub 上扫 `sk-` 前缀的爬虫是分钟级的。

---

## 核心特性

| 特性 | 说明 |
|---|---|
| 🔑 开箱即用 | API 密钥内置，无登录流程，启动即对话 |
| 💬 流式对话 | 标准 OpenAI SSE，逐字上屏，带停止按钮 |
| 🗂 本地历史 | 多会话本地存储，可新建 / 切换 / 删除 / 清空 |
| 🧠 深度思考 | 可切换思考模式（默认关闭，见下方「最大的坑」） |
| 🔍 **联网搜索** | 用 function calling + 客户端抓取实现，**不需要第三方密钥** |
| 🎡 表冠交互 | 对话页翻上下文 / 设置页调字号（`onDigitalCrown`） |
| ⭕ 圆形表盘 | 全屏圆角裁切 + 圆方程逐行算宽，内容不被圆弧切掉 |
| 🔋 省电设计 | 配置内存缓存、请求完成即释放句柄 |

---

## 技术亮点

### 1. 最大的坑：`thinking` 省略 = 默认**开启**思考

实测（`max_tokens=10`）：

```bash
# 不传 thinking 字段
{"messages":[{"role":"user","content":"hi"}],"model":"deepseek-flash","max_tokens":10}
# → content: ""                    ← 空的！
# → reasoning_content: "The user just said \"hi\"…"
# → finish_reason: "length"        ← 10 个 token 全花在思考上
```

手表场景下这是致命的：用户盯着空白等很久。
所以请求体**无条件**输出 `thinking` 字段，关闭时传 `{"type":"disabled"}`。

> **纪律：任何依赖服务端默认值的字段，都必须显式传。**
> 默认值会变，而「省略」这个行为在代码里看不出来。

### 2. 联网搜索：官方 API 没有，但可以用 function calling 做出来

```
① 请求带 web_search 工具声明
② 模型返回 tool_calls {"query":"今日科技新闻"}
③ 【客户端】抓 Bing 结果页 → 解析标题/链接/摘要
④ 作为 role:"tool" 消息回灌，再请求一次
⑤ 模型基于真实结果作答
```

实测输出：

```
模型要搜: 今日科技新闻
取到 10 条，首条: 科技新闻_央视网 (cctv.com)
最终回答: 据 Readhub 每日早报（12小时前），今天的科技热点包括 OpenAI 因数据泄露解雇三名安全研究员…
```

搜索源选型实测：DuckDuckGo **直连超时不可用**；Bing 中文站返回 97KB 真实结果页，
`<li class="b_algo">` 结构稳定。

**搜索失败绝不升级成「整个回答失败」** —— 拿不到结果时，
会明确告诉模型「不要编造」，对话继续。

### 3. 消息「发不出去」的真凶：ArkUI 的 ForEach 不重渲染

这个 bug 极隐蔽：日志显示内容**明明解析成功**，但聊天气泡**永远是空的**。

根因是两件事叠加：

1. `@State` 只在**引用变化**时通知刷新 —— 原地改 `list[i].content` 等于什么都没发生；
2. `ForEach` 按 key 做 diff —— 流式助手消息的 key 固定，判定「无需重绘」。

**修法**：给消息加 `rev` 版本号，每次更新**构造新对象 + `rev++`**，
`ForEach` 的 key 改为 `key + '_' + rev`。

### 4. 注入测试抓到了「假绿」

`trimForSend`（上下文裁剪）里有一段「往前回溯，避免产生孤立 tool 消息」的逻辑。
注入测试（故意删掉它）**最初没被捕获** —— 排查发现那条分支**从没被执行过**：
当时用例的裁剪落点恰好是 `assistant`，绕过了 `while (role === TOOL) start--`。

**代码是对的，但「它对的证据」是假的。**

修法不是把参数改对，而是：把校验逻辑抽成独立的 `validateApiSequence`，
测试改成断言**结构不变量**，并对**所有 max 取值**穷举验证。

> **从没红过的检查等于没有检查。** 详见 `tools/mutate.py`。

### 5. 圆形屏适配

- 最外层 `.borderRadius('50%').clip(true)`
- `RoundScreen.ets` 提供 `widthAtY()`（圆方程算某高度的可用宽度）、`wPct()`、`topInset`
- ⚠️ **466 屏 density=2 ⇒ 1vp = 2px**，算布局尺寸必须换算，否则必然溢出
- ⚠️ **越靠下弦宽越窄**：y=415 弦宽 291px，y=450 弦宽 170px，y=466 弦宽 0。
  且 **y ≥ 450 是系统手势区**（点这里会把 App 推到后台）。
  → 底部可点元素的下沿必须 ≤ 436

---

## 快速开始

```bash
# 用 DevEco Studio (>= 5.0) 打开本目录
# 1. File > Open > 选择 DeepSeekWatch/
# 2. 配置签名（自动签名，需登录华为开发者账号）
# 3. 在 entry/src/main/ets/common/Constants.ets 填入你的 API 密钥
# 4. Build > Build Hap(s)/APP(s) > Build Hap(s)
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
./tools/d.sh install entry/build/default/outputs/default/entry-default-signed.hap
```

---

## 目录速览

```
entry/src/main/ets/
├── pages/        Index（启动）/ ChatPage（对话+设置）/ SessionsPage（历史）
├── components/   RoundWidgets.ets   圆屏组件库
├── model/        ApiClient（HTTP+SSE+工具循环）
│                 SearchService（Bing 抓取解析）
│                 ChatStore（本地会话+裁剪+校验）
│                 AppConfig（设置读写）
└── common/       Constants（API 契约）/ RoundScreen（圆屏几何）
                  Crown（表冠）/ Store（Preferences 封装）
```

---

## 验证体系

> **核心理念：测试质量 = 交付质量。**
> 手表上验证一轮要 3~5 分钟，协议层的问题必须在 PC 上几秒钟验证完。

```bash
# 1. 协议层回归（116 项，不需网络）
node tools/api-protocol-test.mjs

# 2. 注入测试（10 个注入点，验证测试本身有效）
python tools/mutate.py all

# 3. 真实 API 全链路（23 项，需网络）
node tools/live-e2e.mjs
```

| 脚本 | 用途 |
|---|---|
| `ets-load.mjs` | 把 `.ets` 机械剥离类型后当 ES module 跑 —— **测真源码，不测副本** |
| `api-protocol-test.mjs` | SSE 分块边界 / 帧解析 / 工具参数拼接 / 错误分流 / 裁剪 / 请求体 / 搜索解析 |
| `mutate.py` | **注入测试**：故意改坏源码，确认测试变红 |
| `live-e2e.mjs` | 打真实 API：流式 / 思考 / **联网搜索完整往返** / 错误路径 |
| `build.sh` / `d.sh` / `w.sh` | 构建 / hdc 直通 / 手表调试（`shot` `tap` `text` `key` `tree`） |

> ⚠️ 真机调试纪律：
> - **每次点击前先截图或读布局树确认当前屏幕**，不要盲点连续坐标；
> - 定位坐标用 `./tools/w.sh tree` 读布局树的 `bounds`，别靠肉眼估；
> - 输入法是**全屏窗口**，会完全盖住 App，收键盘只能靠系统 Back。

## 文档

- [官方 API 架构 v2](docs/官方API架构_v2.md) — **当前架构**：协议要点、搜索实现、验证体系
- [鸿蒙手表应用开发 · AI 执行手册](docs/鸿蒙手表应用开发_AI执行手册.md) — **想自己做一个手表 App 就从这份开始**
- [交接文档](docs/交接文档_下一任AI.md) — 历史 Bug 的根因与修法、真机验证方法
- [鸿蒙实战教程](docs/鸿蒙开发实战教程.md) — 圆屏适配、表冠、输入法等踩坑记录

---

## 许可

MIT License，详见 [LICENSE](LICENSE)。
