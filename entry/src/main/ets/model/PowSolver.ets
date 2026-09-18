import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DeepSeekHash } from '../common/DeepSeekHash';
import { solvePowAsync } from './PowTask';
import { DsApi } from '../common/Constants';
import { Http } from './Http';

const TAG: string = 'PowSolver';

/** 挑战 */
export interface PowChallenge {
  algorithm: string;
  challenge: string;
  salt: string;
  difficulty: number;
  expire_at: number;
  expire_after: number;
  signature: string;
}

/** 求解结果 */
export interface PowResult {
  answer: number;
  durationMs: number;
}

/** PoW 失败原因：用于给用户**不同**的提示（否则一律"请重试"毫无指导意义） */
export class PowFail {
  /** 取挑战失败（网络 / token / 风控） */
  static readonly NO_CHALLENGE: string = 'pow_no_challenge';
  /** 求解超预算（算力不足或难度异常） */
  static readonly TIMEOUT: string = 'pow_timeout';
}

/**
 * PoW 工作量证明求解器
 *
 * ⚠️ 正确算法（此前实现有三处错误，导致服务端返回 INVALID_POW_RESPONSE、
 *    消息根本没送达）：
 *
 *   1. 哈希不是标准 SHA3-256，而是 DeepSeekHashV1
 *      = Keccak-f[1600] **跳过 round 0**（只做 rounds 1..23）。
 *   2. 前缀是 `salt + "_" + expire_at + "_"`，**不是** `salt + "_"`。
 *   3. 判定是 `hash == challenge`（32 字节精确相等），
 *      不是"摘要前 3 字节 <= difficulty"；
 *      `difficulty` 是 **nonce 搜索范围上界** [0, difficulty)。
 *
 * 流程：
 *   1. POST /api/v0/chat/create_pow_challenge  {target_path}
 *   2. 递增 nonce，算 H(salt_expireAt_nonce)，直到等于 challenge
 *   3. 请求头 X-DS-PoW-Response =
 *      base64(JSON{algorithm,challenge,salt,answer,signature,target_path})
 *
 * 手表适配：
 *   - 分片计算，每片让出主线程（避免 ANR）
 *   - 上报进度，UI 显示"准备中"
 *   - 结果缓存，过期前复用
 */
export class PowSolver {
  private static cache: PowChallenge | null = null;
  private static cachedAnswer: number = -1;
  private static cachedPath: string = '';

  /**
   * 后台预热状态
   *
   * 为什么需要它：
   *   单条消息的 PoW 在手表上要 10~30 秒，用户每次点发送都干等，体感极差。
   *   而服务端挑战 5 分钟内可复用（expire_after=300000），
   *   线上网页端也是按 scene 缓存 PoW 结果复用的（bundle 内 `retrieveAnswer`）。
   *   所以可以在「登录后 / 空闲时 / 上一条消息发完之后」提前把下一道算好，
   *   用户真正发送时直接命中缓存 —— 体感从「转十几秒」变「几乎瞬时」。
   *
   * 并发保护：
   *   prewarming 非空表示已有一道在算，避免重复求解把 CPU 抢光；
   *   prepare() 若发现同一 target_path 正在预热，会等它而不是另起一道。
   */
  private static prewarming: Promise<void> | null = null;
  private static prewarmPath: string = '';

  /** 最近一次求解进度（供 prepare 在「等待预热」时把进度透传给 UI） */
  private static progressTried: number = 0;
  private static progressTotal: number = 0;

  /**
   * 求解硬上限：45 秒。
   *
   * 为什么从 20 秒放宽到 45 秒：
   * 实测手表上 6 秒都没算完（触发 THREAD_BLOCK_6S），说明单次哈希比预期慢，
   * 难度 144000、命中位置平均在 7 万左右，实际可能需要 10~30 秒。
   * 现在计算已经搬到 taskpool 后台线程（且多核并行）—— 不阻塞 UI、不受 6 秒限制，
   * 而且有进度百分比反馈，用户能看出"在动"。
   * 所以宁可多等一会儿，也不要中途放弃让用户白等。
   *
   * 上限仍保留：难度异常时不会无限转圈（taskpool 单任务 CPU 上限是 3 分钟）。
   */
  private static readonly SOLVE_BUDGET_MS: number = 45000;

  /**
   * 取挑战
   *
   * ⚠️ 全程防御式解析：服务端异常/风控拦截时返回结构可能缺字段，
   *    早期版本直接取 res.data.biz_data.challenge 会抛 TypeError。
   */
  static async fetchChallenge(token: string, targetPath: string): Promise<PowChallenge | null> {
    const url: string = DsApi.ORIGIN + DsApi.POW_CHALLENGE;
    const body: string = JSON.stringify({ target_path: targetPath });
    const res = await Http.postJson(url, body, token, null);
    if (res.code !== 0 || res.data === null || res.data.biz_data === null) {
      return null;
    }
    const bd: Record<string, Object> = res.data.biz_data as Record<string, Object>;
    const raw: Object | undefined = bd['challenge'];
    if (raw === undefined || raw === null) {
      return null;
    }
    const c: Record<string, Object> = raw as Record<string, Object>;
    const salt: string = PowSolver.str(c, 'salt');
    const challenge: string = PowSolver.str(c, 'challenge');
    if (salt.length === 0 || challenge.length === 0) {
      return null;
    }
    const difficulty: number = PowSolver.num(c, 'difficulty');
    if (difficulty <= 0) {
      return null;
    }
    return {
      algorithm: PowSolver.str(c, 'algorithm'),
      challenge: challenge,
      salt: salt,
      difficulty: difficulty,
      expire_at: PowSolver.num(c, 'expire_at'),
      expire_after: PowSolver.num(c, 'expire_after'),
      signature: PowSolver.str(c, 'signature')
    };
  }

  private static str(o: Record<string, Object>, k: string): string {
    const v: Object | undefined = o[k];
    if (typeof v === 'string') {
      return v as string;
    }
    return '';
  }

  private static num(o: Record<string, Object>, k: string): number {
    const v: Object | undefined = o[k];
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      const n: number = parseInt(v as string);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }

  /**
   * 求解（跑在 taskpool 后台线程）
   * @param ch 挑战
   * @param onProgress 进度回调 (已尝试次数, 总搜索范围)
   * @returns 解；超预算/未找到返回 null
   */
  static async solve(ch: PowChallenge,
    onProgress?: (tried: number, total: number) => void): Promise<PowResult | null> {
    const start: number = Date.now();
    // ★ 前缀必须带 expire_at，否则服务端判定 PoW 无效
    const prefix: string = ch.salt + '_' + ch.expire_at.toString() + '_';
    hilog.info(0x0001, TAG, 'solve start salt=%{public}s diff=%{public}d',
      ch.salt, ch.difficulty);

    // 记录进度到静态字段：prepare() 在「等待后台预热」时可以把进度透传给 UI，
    // 否则用户会看到进度条一直停在 0% 以为卡死。
    PowSolver.progressTried = 0;
    PowSolver.progressTotal = ch.difficulty;

    // ★ 必须走后台线程：主线程算 PoW 会触发 THREAD_BLOCK_6S 被系统杀进程
    const answer: number = await solvePowAsync(
      prefix, ch.challenge, ch.difficulty, PowSolver.SOLVE_BUDGET_MS,
      (tried: number, total: number) => {
        PowSolver.progressTried = tried;
        PowSolver.progressTotal = total;
        if (onProgress) {
          onProgress(tried, total);
        }
      });

    if (answer < 0) {
      hilog.error(0x0001, TAG, 'solve failed diff=%{public}d', ch.difficulty);
      return null;
    }
    return { answer: answer, durationMs: Date.now() - start };
  }

  /** 组装请求头值 */
  static buildHeaderValue(ch: PowChallenge, answer: number, targetPath: string): string {
    const payload: string = JSON.stringify({
      algorithm: ch.algorithm,
      challenge: ch.challenge,
      salt: ch.salt,
      answer: answer,
      signature: ch.signature,
      target_path: targetPath
    });
    return PowSolver.b64encode(payload);
  }

  /** base64 编码（手表端无 btoa，手工实现，UTF-8 安全） */
  static b64encode(s: string): string {
    const bytes: Uint8Array = new util.TextEncoder().encode(s);
    const table: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out: string = '';
    const len: number = bytes.length;
    let i: number = 0;
    for (; i + 2 < len; i += 3) {
      const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += table[(n >> 18) & 63] + table[(n >> 12) & 63] + table[(n >> 6) & 63] + table[n & 63];
    }
    const rem: number = len - i;
    if (rem === 1) {
      const n: number = bytes[i] << 16;
      out += table[(n >> 18) & 63] + table[(n >> 12) & 63] + '==';
    } else if (rem === 2) {
      const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out += table[(n >> 18) & 63] + table[(n >> 12) & 63] + table[(n >> 6) & 63] + '=';
    }
    return out;
  }

  /**
   * 是否可复用缓存
   *
   * ⚠️ `expire_at` 服务端可能给**秒**或**毫秒**时间戳，
   *    直接用 Date.now() 比较会在秒制下把有效期算错（差 1000 倍）。
   *    这里按量级自动判断：小于 1e12 视为秒。
   */
  static reuseCache(targetPath: string): string | null {
    const c: PowChallenge | null = PowSolver.cache;
    if (c === null || PowSolver.cachedAnswer < 0 || PowSolver.cachedPath !== targetPath) {
      return null;
    }
    if (c.expire_at <= 0) {
      return null;
    }
    const expMs: number = c.expire_at < 1000000000000 ? c.expire_at * 1000 : c.expire_at;
    // 留 10 秒安全余量，避免"刚拿到就过期"
    if (Date.now() > expMs - 10000) {
      return null;
    }
    return PowSolver.buildHeaderValue(c, PowSolver.cachedAnswer, targetPath);
  }

  static saveCache(ch: PowChallenge, answer: number, targetPath: string): void {
    PowSolver.cache = ch;
    PowSolver.cachedAnswer = answer;
    PowSolver.cachedPath = targetPath;
  }

  static clearCache(): void {
    PowSolver.cache = null;
    PowSolver.cachedAnswer = -1;
    PowSolver.cachedPath = '';
  }

  /**
   * 一站式：取挑战 → 求解 → 返回可直接放请求头的值（带缓存）
   *
   * 失败一律返回 null（不抛异常），由调用方转成用户可读提示。
   *
   * 若发现「同一个 target_path 正在后台预热」，这里会**等它**而不是另起一道 ——
   * 否则两道求解会互相抢 CPU，总耗时反而更长。
   */
  static async prepare(token: string, targetPath: string,
    onProgress?: (tried: number, total: number) => void): Promise<string | null> {
    PowSolver.lastFail = '';
    const cached: string | null = PowSolver.reuseCache(targetPath);
    if (cached !== null) {
      return cached;
    }

    // ---- 有同一路径的后台预热在跑 → 等它完成 ----
    if (PowSolver.prewarming !== null && PowSolver.prewarmPath === targetPath) {
      const waited: string | null = await PowSolver.waitPrewarm(targetPath, onProgress);
      if (waited !== null) {
        return waited;
      }
    }

    // 哈希实现自检（单次哈希，开销可忽略；失败说明移植有问题，便于现场排查）
    DeepSeekHash.selfTest();
    try {
      const ch: PowChallenge | null = await PowSolver.fetchChallenge(token, targetPath);
      if (ch === null) {
        PowSolver.lastFail = PowFail.NO_CHALLENGE;
        return null;
      }
      const r: PowResult | null = await PowSolver.solve(ch, onProgress);
      if (r === null) {
        // 求解返回 null 只可能是「超预算」——分出来，用户看到的提示才有意义
        PowSolver.lastFail = PowFail.TIMEOUT;
        return null;
      }
      PowSolver.saveCache(ch, r.answer, targetPath);
      return PowSolver.buildHeaderValue(ch, r.answer, targetPath);
    } catch (e) {
      PowSolver.lastFail = PowFail.NO_CHALLENGE;
      return null;
    }
  }

  /**
   * 上一次 prepare 的失败原因（空串 = 没失败过）
   *
   * ★ 为什么要有它：PoW 失败有两种完全不同的病因 ——
   *   「没拿到挑战」（网络/token/风控，重试可能有用）与
   *   「求解超时」（算力不够，重试大概率还是超时，应该提示换网或稍后再试）。
   *   两者都回一个 null 的话，UI 只能笼统说"安全校验失败，请重试"，
   *   用户会陷入无效重试。
   */
  private static lastFail: string = '';

  static getLastFail(): string {
    return PowSolver.lastFail;
  }

  /**
   * 后台预热：提前把下一道 PoW 算好放进缓存
   *
   * 调用时机：登录成功、进入对话页、以及每次消息发送结束后。
   * 完全 fire-and-forget：不阻塞 UI，失败静默（真正发送时 prepare 会再兜一次）。
   */
  static prewarm(token: string, targetPath: string): void {
    if (token.length === 0) {
      return;
    }
    // 已有可用缓存 → 不用再算
    if (PowSolver.reuseCache(targetPath) !== null) {
      return;
    }
    // 已有预热在跑 → 不重复起
    if (PowSolver.prewarming !== null) {
      return;
    }
    PowSolver.prewarmPath = targetPath;
    PowSolver.prewarming = PowSolver.doPrewarm(token, targetPath);
  }

  private static async doPrewarm(token: string, targetPath: string): Promise<void> {
    try {
      const ch: PowChallenge | null = await PowSolver.fetchChallenge(token, targetPath);
      if (ch === null) {
        return;
      }
      const r: PowResult | null = await PowSolver.solve(ch);
      if (r === null) {
        return;
      }
      PowSolver.saveCache(ch, r.answer, targetPath);
      hilog.info(0x0001, TAG, 'prewarm done answer=%{public}d ms=%{public}d',
        r.answer, r.durationMs);
    } catch (e) {
      // 预热失败无所谓，真正发送时还会重来
    } finally {
      PowSolver.prewarming = null;
      PowSolver.prewarmPath = '';
    }
  }

  /**
   * 等待后台预热结束，并把进度透传给 UI
   *
   * 进度来自 solve() 写入的静态字段 —— 预热那道题的进度就是用户看到的进度，
   * 不会出现「进度条一直 0%」的假死观感。
   *
   * ★ 超时上限不能太长（2026-09-18 调整）：
   *   旧实现死等 60 秒。如果预热那道题在极端情况下卡住（原生模块 hang、
   *   任务调度迟迟不返回），用户点发送后会**先呆等 60 秒**才开始真正求解 ——
   *   本来 200ms 的事变成一分钟，观感上就是「点了没反应」。
   *   现在改为：每轮循环检查是否已经超时才停，
   *   并且上限收到 20 秒 —— 超过就自己解，**不陪跑**。
   *   （正常的预热 200~300ms 就完了，20 秒已经是非常宽松的异常兜底。）
   *
   * @returns 预热成功后可直接用的请求头值；失败/超时返回 null（调用方自己再解一次）
   */
  private static async waitPrewarm(targetPath: string,
    onProgress?: (tried: number, total: number) => void): Promise<string | null> {
    const start: number = Date.now();
    const LIMIT_MS: number = 20000;
    while (PowSolver.prewarming !== null) {
      // 先看结果：已经算好了就立刻返回，不用等 prewarming 清空
      const cached: string | null = PowSolver.reuseCache(targetPath);
      if (cached !== null) {
        return cached;
      }
      if (Date.now() - start >= LIMIT_MS) {
        hilog.warn(0x0001, TAG,
          'waitPrewarm timeout after %{public}dms — solving on our own',
          Date.now() - start);
        break;
      }
      if (onProgress && PowSolver.progressTotal > 0) {
        onProgress(PowSolver.progressTried, PowSolver.progressTotal);
      }
      await PowSolver.sleep(150);
    }
    return PowSolver.reuseCache(targetPath);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
