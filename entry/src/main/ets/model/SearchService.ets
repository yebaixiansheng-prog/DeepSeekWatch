/**
 * 联网搜索服务
 *
 * ★ 2026-09-30 新写（用户说「联网搜索你看看能不能想办法做一下，实在不行就算了」）
 *
 * 结论：**能做**，且不需要任何第三方 API 密钥。链路：
 *   ① 请求给模型带 `web_search` 工具声明（见 ApiClient.SearchTools）；
 *   ② 模型返回 tool_calls → 本服务去抓 Bing 结果页；
 *   ③ 解析出标题/链接/摘要 → 拼成纯文本回灌给模型。
 *
 * 为什么选 Bing（2026-09-30 实测）：
 *   · DuckDuckGo（lite + api）→ **直连超时**（HTTP 000，20s 无响应），不可用；
 *   · Bing 中文站 → HTTP 200，返回真实结果页（97KB），`<li class="b_algo">` 结构稳定；
 *   · 百度/搜狗 → 可返回 200，但反爬更激进，作为备选不在首版启用。
 *
 * ⚠️ 解析规则是「依赖第三方页面结构」的，脆弱是本质的。因此：
 *   · 解析失败的判据是「条目数为 0」，**不是抛异常**；
 *   · 上层拿到 0 条也会继续对话（让模型诚实说「没搜到」），而不是让回答失败；
 *   · `parseBing` 是纯函数，有专门的离线回归测试（见 tools/search-parse-test.mjs）。
 */

import http from '@ohos.net.http';
import { SearchCfg, DsHeader } from '../common/Constants';

/** 一条搜索结果 */
export interface SearchItem {
  title: string;
  url: string;
  snippet: string;
}

/** 抓取 + 解析的完整结果 */
export interface SearchOutcome {
  ok: boolean;
  /** 失败原因（ok=false 时有值） */
  reason: string;
  query: string;
  items: SearchItem[];
}

/**
 * ★ Bing 结果页解析（纯函数，可在 Node 里跑）
 *
 * 输入：Bing 搜索结果页 HTML
 * 输出：结果条目数组（可能为空 = 没解析出来）
 *
 * 实现说明：
 *   · 不引入 HTML 解析库（手表端体积敏感），用朴素的标签扫描；
 *   · `<li class="b_algo">` 是 Bing 的结果单元，用它切块；
 *   · 标题在块内第一个 `<h2>` 里（可能包着 `<a>`）；
 *   · 链接取块内第一个 `href="http...`；
 *   · 摘要在 `<p>` 里。
 *
 * ⚠️ 反例（写测试时必须覆盖）：结构变化 → 返回空数组，**不是**抛异常、
 *    也**不是**返回垃圾条目（比如把导航栏当成结果）。
 */
export function parseBing(html: string): SearchItem[] {
  if (html.length === 0) {
    return [];
  }
  const out: SearchItem[] = [];

  // 切出所有 b_algo 块
  const blocks: string[] = extractBlocks(html, 'b_algo');

  for (const blk of blocks) {
    const title: string = cleanText(firstTag(blk, 'h2'));
    const url: string = firstHref(blk);
    const snippet: string = cleanText(firstParagraph(blk));

    // 过滤明显无效的条目：没有链接的一律丢弃
    if (url.length === 0) {
      continue;
    }
    if (title.length === 0 && snippet.length === 0) {
      continue;
    }
    out.push({
      title: title.length > 0 ? title : url,
      url: url,
      snippet: snippet
    });
    if (out.length >= 12) {
      break;
    }
  }
  return out;
}

/** 取出所有 class 含 name 的 <li ...> ... </li> 块 */
function extractBlocks(html: string, className: string): string[] {
  const out: string[] = [];
  const marker: string = 'class="' + className;
  let from: number = 0;
  while (true) {
    const hit: number = html.indexOf(marker, from);
    if (hit < 0) {
      break;
    }
    // 回退到该标签起始
    const open: number = html.lastIndexOf('<li', hit);
    const start: number = open >= 0 ? open : hit;
    const end: number = html.indexOf('</li>', hit);
    if (end < 0) {
      break;
    }
    out.push(html.substring(start, end));
    from = end + 5;
    if (out.length >= 40) {
      break;
    }
  }
  return out;
}

/** 取第一个 <tag ...> ... </tag> 的内文 */
function firstTag(html: string, tag: string): string {
  const open: number = html.indexOf('<' + tag);
  if (open < 0) {
    return '';
  }
  const gt: number = html.indexOf('>', open);
  if (gt < 0) {
    return '';
  }
  const close: number = html.indexOf('</' + tag + '>', gt);
  if (close < 0) {
    return '';
  }
  return html.substring(gt + 1, close);
}

/** 取第一个 <p ...> ... </p> 的内文 */
function firstParagraph(html: string): string {
  return firstTag(html, 'p');
}

/** 取第一个 http(s) 链接 */
function firstHref(html: string): string {
  let from: number = 0;
  while (true) {
    const hit: number = html.indexOf('href="', from);
    if (hit < 0) {
      return '';
    }
    const start: number = hit + 6;
    const end: number = html.indexOf('"', start);
    if (end < 0) {
      return '';
    }
    const u: string = html.substring(start, end);
    if (u.startsWith('http://') || u.startsWith('https://')) {
      return u;
    }
    from = end + 1;
  }
}

/**
 * 去标签 + 解实体 + 压空白
 * ★ 顺序很关键：先解实体再压空白，否则 `&ensp;` 会被当成普通文本保留下来
 */
export function cleanText(s: string): string {
  let t: string = s;
  // <script>/<style> 内容直接扔掉
  t = stripTagBlock(t, 'script');
  t = stripTagBlock(t, 'style');
  // 去标签
  t = t.replace(/<[^>]*>/g, '');
  // 解常见实体
  t = t.replace(/&nbsp;/g, ' ').replace(/&#160;/g, ' ')
    .replace(/&ensp;/g, ' ').replace(/&#8194;/g, ' ')
    .replace(/&emsp;/g, ' ').replace(/&#8195;/g, ' ')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, '\'').replace(/&apos;/g, '\'')
    .replace(/&#183;/g, '·').replace(/&middot;/g, '·');
  // 数字实体兜底
  t = t.replace(/&#(\d+);/g, (_m: string, d: string) => {
    const n: number = parseInt(d, 10);
    return isNaN(n) ? '' : String.fromCharCode(n);
  });
  // 压空白
  t = t.replace(/\s+/g, ' ');
  return t.trim();
}

/** 移除 <tag>...</tag> 整块 */
function stripTagBlock(html: string, tag: string): string {
  let out: string = html;
  while (true) {
    const a: number = out.indexOf('<' + tag);
    if (a < 0) {
      break;
    }
    const b: number = out.indexOf('</' + tag + '>', a);
    if (b < 0) {
      break;
    }
    out = out.substring(0, a) + out.substring(b + tag.length + 3);
  }
  return out;
}

/**
 * 把搜索结果拼成给模型看的纯文本
 *
 * ★ 明确标注「这是搜索结果、可能过时」，
 *   并在为空时给出**可直接使用的失败说明**，避免模型自信编造。
 */
export function formatForModel(query: string, items: SearchItem[]): string {
  if (items.length === 0) {
    return '【联网搜索：未找到"' + query + '"的结果】\n'
      + '（搜索源未返回可用条目，可能被限流或改版。'
      + '请如实告知用户你没能检索到实时信息，不要编造。）';
  }
  const lines: string[] = [];
  lines.push('【联网搜索："' + query + '" 的结果，共 ' + items.length.toString() + ' 条】');
  lines.push('（以下是搜索引擎返回的网页摘要，可能不完整或过时，请结合它回答，并注明信息来源）');
  for (let i = 0; i < items.length; i++) {
    const it: SearchItem = items[i];
    lines.push('');
    lines.push((i + 1).toString() + '. ' + it.title);
    if (it.snippet.length > 0) {
      lines.push('   ' + it.snippet);
    }
    lines.push('   来源：' + it.url);
  }
  return lines.join('\n');
}

/**
 * 搜索服务
 */
export class SearchService {
  /**
   * 执行一次搜索。
   * ★ 本方法**永不抛异常** —— 失败也返回 ok=false 的结果对象，
   *   由调用方（ApiClient）决定如何回灌给模型。这是「必有失败出口」纪律的体现。
   */
  static async search(query: string): Promise<SearchOutcome> {
    const q: string = query.trim();
    if (q.length === 0) {
      return { ok: false, reason: 'empty_query', query: q, items: [] };
    }

    const url: string = SearchCfg.ENDPOINT + '?q=' + encodeURIComponent(q)
      + '&setlang=zh-CN&ensearch=0';

    const handle: http.HttpRequest = http.createHttp();
    let html: string = '';
    try {
      const resp: http.HttpResponse = await handle.request(url, {
        method: http.RequestMethod.GET,
        header: SearchService.browserHeaders(),
        connectTimeout: SearchCfg.TIMEOUT_MS,
        readTimeout: SearchCfg.TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode !== 200) {
        return {
          ok: false,
          reason: 'http_' + resp.responseCode.toString(),
          query: q,
          items: []
        };
      }
      html = typeof resp.result === 'string' ? (resp.result as string) : '';
    } catch (e) {
      return { ok: false, reason: 'network', query: q, items: [] };
    } finally {
      try {
        handle.destroy();
      } catch (e) {
        // 忽略
      }
    }

    if (html.length === 0) {
      return { ok: false, reason: 'empty_body', query: q, items: [] };
    }

    const items: SearchItem[] = parseBing(html);
    // 只留前 N 条：手表上下文紧张，多了会挤掉对话本身
    const trimmed: SearchItem[] = items.length > SearchCfg.MAX_RESULTS
      ? items.slice(0, SearchCfg.MAX_RESULTS)
      : items;

    return {
      ok: trimmed.length > 0,
      reason: trimmed.length > 0 ? '' : 'no_result',
      query: q,
      items: trimmed
    };
  }

  /**
   * 抓取用的请求头
   * ⚠️ 必须像个真浏览器：Bing 对无 UA 的请求会返回精简页/拦截页。
   */
  private static browserHeaders(): Record<string, string> {
    const h: Record<string, string> = {};
    h['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
    h[DsHeader.ACCEPT] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    h['Accept-Language'] = 'zh-CN,zh;q=0.9';
    return h;
  }
}
