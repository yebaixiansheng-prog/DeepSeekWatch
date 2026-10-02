/**
 * 官方 API 契约常量
 *
 * ★ 2026-09-30 推倒重来
 *   本文件替代了旧的 `Constants.ets`（那是 chat.deepseek.com 网页版的逆向契约，
 *   含 PoW / 设备指纹 / 私有 SSE 帧格式，已全部删除）。
 *
 *   现在走 **DeepSeek 官方开放平台**：标准 OpenAI 兼容协议。
 *   实测结论（2026-09-30，curl 直连）：
 *     · 端点      POST https://api.deepseek.com/chat/completions
 *     · 鉴权      `Authorization: Bearer <API_KEY>`（不需要任何设备指纹/PoW）
 *     · 流式      标准 SSE，`data: {...}` 逐块，`choices[0].delta.content`
 *     · 结束      `data: [DONE]`
 *     · 模型      deepseek-flash / deepseek-v4-pro
 */

import { LocalKey } from './LocalKey';

export class DsApi {
  /** 官方 API 根 */
  static readonly ORIGIN: string = 'https://api.deepseek.com';
  /** 对话补全（流式/非流式同一个端点，靠 body 里的 stream 区分） */
  static readonly CHAT: string = '/chat/completions';
  /** 余额查询（用于设置页显示，可选） */
  static readonly BALANCE: string = '/user/balance';
}

/**
 * ★★ API 密钥
 *
 * 密钥**不写在本文件里**，而是放在 `LocalKey.ets`。原因：
 *   本仓库是**公开**的，GitHub 上扫 `sk-` 前缀的爬虫是**分钟级**的 ——
 *   密钥一旦提交，几分钟内就会被抓走盗刷。这不是理论风险，是常态。
 *
 *   `LocalKey.ets` 在版本库里是**空值**（保证任何人 clone 都能编译），
 *   你自己的真实密钥填在本地那一份里，由 `.gitignore` + pre-commit 钩子
 *   保证永远不会被提交。
 *
 * 优先级：设置页填的（存 Preferences） > LocalKey.ets > 空
 *   读不到任何密钥时，应用会明确提示「尚未配置 API 密钥」，
 *   **不会**用一个假密钥去请求然后报一堆看不懂的网络错误。
 *   （纪律：「未配置」和「网络失败」是两种错误，不许复用同一句文案。）
 */
export class ApiKey {
  /** 内置密钥（来自本地文件；仓库里为空串） */
  static readonly BUILTIN: string = LocalKey.VALUE;
}

/** 模型 ID（实测可用） */
export class Model {
  /** 快速版：响应快、便宜，手表默认 */
  static readonly FLASH: string = 'deepseek-flash';
  /** 专业版：能力更强，可切换 */
  static readonly PRO: string = 'deepseek-v4-pro';

  static all(): string[] {
    return [Model.FLASH, Model.PRO];
  }

  static label(m: string): string {
    if (m === Model.PRO) {
      return '专业版';
    }
    return '快速版';
  }
}

/**
 * 思考模式
 *
 * ★ 实测踩坑（2026-09-30）：
 *   **不传 `thinking` 字段时，默认是「开启思考」**。
 *   实测 `{"model":"deepseek-flash"}` + `max_tokens:10` 的响应：
 *     `content: ""`，10 个 token 全部花在 `reasoning_content` 上。
 *   → 手表场景必须先看到文字，所以**默认关闭**，由用户在设置里开。
 *   → 关闭方式是显式传 `thinking: {type: 'disabled'}`，不能靠省略。
 */
export class Thinking {
  static readonly ON: string = 'enabled';
  static readonly OFF: string = 'disabled';
}

/** 角色 */
export class Role {
  static readonly SYSTEM: string = 'system';
  static readonly USER: string = 'user';
  static readonly ASSISTANT: string = 'assistant';
  /** 工具执行结果回灌 */
  static readonly TOOL: string = 'tool';
}

/**
 * 联网搜索
 *
 * ★ 方案（2026-09-30 实测确定，无需任何第三方密钥）：
 *   DeepSeek 官方 API **没有**内置联网搜索，但支持标准 `tools` / function calling
 *   （已实测：模型会正确返回 `tool_calls`，`finish_reason: "tool_calls"`）。
 *   借这条路做「客户端执行搜索」：
 *     ① 请求带上 `web_search` 工具声明；
 *     ② 模型判断需要实时信息 → 返回 `tool_calls`，参数是 `{"query": "..."}`；
 *     ③ **客户端**去抓 Bing 搜索结果页，解析出标题/链接/摘要；
 *     ④ 把结果作为 `role: tool` 消息追加进对话，再发一次请求；
 *     ⑤ 模型基于真实搜索结果作答。
 *
 *   ⚠️ 兜底：搜索源可能改版或不可达。任何一步失败都必须
 *      ① 明确告知用户「搜索没成功」，② 让对话**继续**（不要卡死），
 *      ③ 把失败原因告诉模型，让它可以诚实回答「我没搜到」。
 *      绝不允许「搜索失败 → 整个回答失败」。
 */
export class SearchCfg {
  /** 工具名（发给模型的 function name） */
  static readonly TOOL_NAME: string = 'web_search';
  /** 搜索源：Bing 中文站（实测可达，返回真实结果页） */
  static readonly ENDPOINT: string = 'https://cn.bing.com/search';
  /** 抓取超时（ms） */
  static readonly TIMEOUT_MS: number = 12000;
  /** 最多取几条结果灌给模型（多了吃 token，手表上下文紧张） */
  static readonly MAX_RESULTS: number = 5;
  /** 单次多轮工具调用上限，防「模型无限调工具」死循环 */
  static readonly MAX_ROUNDS: number = 2;
}

/** 请求头 */
export class DsHeader {
  static readonly AUTH: string = 'Authorization';
  static readonly CONTENT_TYPE: string = 'Content-Type';
  static readonly ACCEPT: string = 'Accept';
  static readonly BEARER: string = 'Bearer ';
}

/** 错误码（本应用自定义，用于 UI 区分处理方式） */
export class ErrCode {
  /** 成功 */
  static readonly OK: number = 0;
  /** 网络不可达 / 超时 */
  static readonly NETWORK: number = -1;
  /** 密钥无效（HTTP 401/403） */
  static readonly AUTH: number = -2;
  /** 余额不足（HTTP 402） */
  static readonly NO_BALANCE: number = -3;
  /** 限流（HTTP 429） */
  static readonly RATE_LIMIT: number = -4;
  /** 服务端 5xx */
  static readonly SERVER: number = -5;
  /** 响应体解析失败（非 JSON / 空体 / HTML） */
  static readonly BAD_PAYLOAD: number = -6;
  /** 请求被用户中止 */
  static readonly ABORTED: number = -7;
  /** 服务端返回了业务错误（body 里有 error 字段） */
  static readonly BIZ: number = -8;
}

/**
 * 错误文案（唯一出口）
 *
 * ★ 纪律：**「未配置」「网络失败」「鉴权失败」「余额不足」是四种不同的错误，
 *   绝不允许复用同一句文案。** 用户要能一眼看出该做什么。
 */
export class ErrMsg {
  static readonly NETWORK: string = '网络不通，请检查手表 Wi-Fi';
  static readonly AUTH: string = 'API 密钥无效，请在设置里重新填写';
  static readonly NO_BALANCE: string = '账户余额不足，请先充值';
  static readonly RATE_LIMIT: string = '请求太频繁，请稍后再试';
  static readonly SERVER: string = 'DeepSeek 服务暂时不可用，请稍后重试';
  static readonly BAD_PAYLOAD: string = '服务端返回了无法识别的数据，请稍后重试';
  static readonly ABORTED: string = '已停止';
  static readonly NO_KEY: string = '尚未配置 API 密钥';
}
