import nativeHash from 'libentry.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'NativeHash';

/**
 * DeepSeekHashV1 / PoW 搜索的**原生（C++）实现**包装
 *
 * 为什么需要它：
 *   ArkTS 版实现在 HUAWEI WATCH 5 上实测只有约 1000~2000 次哈希/秒，
 *   一次难度 144000 的 PoW 要 **20~55 秒**（真机实测三次：44s / 23s / 54s）。
 *   同一算法用 C++ 编译后是毫秒级，这是唯一能真正解决「安全校验太慢」的办法。
 *
 * 安全策略：
 *   1. 启动时用**真实抓包向量**做一次自检（hashHex + searchRange 各一次）；
 *   2. 自检不通过 / 原生模块加载失败 → 一律返回 false，
 *      调用方回退到已验证的 ArkTS 实现（慢但正确），**绝不因为原生模块出问题而发不出消息**。
 */
export class NativeHash {
  /** 真实抓包向量（与 DeepSeekHash.selfTest 用的是同一组） */
  private static readonly V_SALT: string = '82a875dd6f0757241fed';
  private static readonly V_EXPIRE: string = '1789207715395';
  private static readonly V_ANSWER: number = 11747;
  private static readonly V_CHALLENGE: string =
    'ccfdd5b03a194eaacdfd7678b083a68aa3968f2406841c0ceaeff97ef935758e';

  private static checked: boolean = false;
  private static ok: boolean = false;

  /** 原生模块是否可用且结果正确（只自检一次） */
  static isOk(): boolean {
    if (NativeHash.checked) {
      return NativeHash.ok;
    }
    NativeHash.checked = true;
    try {
      const prefix: string = NativeHash.V_SALT + '_' + NativeHash.V_EXPIRE + '_';
      const h: string = nativeHash.hashHex(prefix + NativeHash.V_ANSWER.toString());
      const hit: number = nativeHash.searchRange(prefix, NativeHash.V_CHALLENGE, 0, 144000);
      NativeHash.ok = (h === NativeHash.V_CHALLENGE) && (hit === NativeHash.V_ANSWER);
      hilog.info(0x0001, TAG, 'native selfTest=%{public}s hit=%{public}d',
        NativeHash.ok ? 'PASS' : 'FAIL', hit);
    } catch (e) {
      NativeHash.ok = false;
      hilog.error(0x0001, TAG, 'native module unavailable: %{public}s', JSON.stringify(e));
    }
    return NativeHash.ok;
  }

  /**
   * 在 [from, to) 内搜索 nonce
   *
   * ⚠️ 调用前应先用 isOk() 确认；本方法不吞异常（由调用方兜底），
   *    这样出问题时会走回退路径而不是静默返回 -1 导致「PoW 永远算不出来」。
   */
  static searchRange(prefix: string, challengeHex: string, from: number, to: number): number {
    return nativeHash.searchRange(prefix, challengeHex, from, to);
  }
}
