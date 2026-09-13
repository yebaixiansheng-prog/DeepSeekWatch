import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * DeepSeekHashV1 —— DeepSeek 官网 PoW 使用的哈希
 *
 * ⚠️ 它不是标准 SHA3-256。与标准的唯一差异：
 *    Keccak-f[1600] 只做 **rounds 1..23**（跳过 round 0），其余（rate=136、
 *    填充 0x06…0x80、输出 32 字节）与 SHA3-256 完全一致。
 *    若误用标准 SHA3-256，服务端一律返回
 *      {"code":40301,"msg":"INVALID_POW_RESPONSE"}
 *    消息根本不会送达 —— 这正是本项目此前"消息发不出去"的根因。
 *
 * 实现要点（手表适配）：
 *   - 64 位 lane 用两个 32 位整数表示（hi / lo）。不用 BigInt：
 *     BigInt 版在手表上单次哈希约 0.2ms，144000 次尝试要 30 秒以上，不可用。
 *   - ρ/π 手工展开为 25 条语句，避免内层取模/分支。
 *   - 求解时复用"前缀状态"，每次只重算受 nonce 影响的 2 个 lane。
 */

/** ι 常量的高/低 32 位 */
const RC_H: number[] = [
  0x00000000, 0x00000000, 0x80000000, 0x80000000,
  0x00000000, 0x00000000, 0x80000000, 0x80000000,
  0x00000000, 0x00000000, 0x00000000, 0x00000000,
  0x00000000, 0x80000000, 0x80000000, 0x80000000,
  0x80000000, 0x80000000, 0x00000000, 0x80000000,
  0x80000000, 0x80000000, 0x00000000, 0x80000000
];

const RC_L: number[] = [
  0x00000001, 0x00008082, 0x0000808A, 0x80008000,
  0x0000808B, 0x80000001, 0x80008081, 0x00008009,
  0x0000008A, 0x00000088, 0x80008009, 0x8000000A,
  0x8000808B, 0x0000008B, 0x00008089, 0x00008003,
  0x00008002, 0x00000080, 0x0000800A, 0x8000000A,
  0x80008081, 0x00008080, 0x80000001, 0x80008008
];

const LANES: number = 25;
const RATE: number = 136;
const TAG: string = 'DsHash';

/**
 * Keccak-f[1600]，rounds 1..23
 * H/L 为输入状态（原地修改），BH/BL 为复用的临时缓冲
 */
function permute(H: Int32Array, L: Int32Array, BH: Int32Array, BL: Int32Array): void {
  for (let r = 1; r < 24; r++) {
    // ---------------- θ ----------------
    const c0h: number = H[0] ^ H[5] ^ H[10] ^ H[15] ^ H[20];
    const c0l: number = L[0] ^ L[5] ^ L[10] ^ L[15] ^ L[20];
    const c1h: number = H[1] ^ H[6] ^ H[11] ^ H[16] ^ H[21];
    const c1l: number = L[1] ^ L[6] ^ L[11] ^ L[16] ^ L[21];
    const c2h: number = H[2] ^ H[7] ^ H[12] ^ H[17] ^ H[22];
    const c2l: number = L[2] ^ L[7] ^ L[12] ^ L[17] ^ L[22];
    const c3h: number = H[3] ^ H[8] ^ H[13] ^ H[18] ^ H[23];
    const c3l: number = L[3] ^ L[8] ^ L[13] ^ L[18] ^ L[23];
    const c4h: number = H[4] ^ H[9] ^ H[14] ^ H[19] ^ H[24];
    const c4l: number = L[4] ^ L[9] ^ L[14] ^ L[19] ^ L[24];

    const d0h: number = c4h ^ ((c1h << 1) | (c1l >>> 31));
    const d0l: number = c4l ^ ((c1l << 1) | (c1h >>> 31));
    const d1h: number = c0h ^ ((c2h << 1) | (c2l >>> 31));
    const d1l: number = c0l ^ ((c2l << 1) | (c2h >>> 31));
    const d2h: number = c1h ^ ((c3h << 1) | (c3l >>> 31));
    const d2l: number = c1l ^ ((c3l << 1) | (c3h >>> 31));
    const d3h: number = c2h ^ ((c4h << 1) | (c4l >>> 31));
    const d3l: number = c2l ^ ((c4l << 1) | (c4h >>> 31));
    const d4h: number = c3h ^ ((c0h << 1) | (c0l >>> 31));
    const d4l: number = c3l ^ ((c0l << 1) | (c0h >>> 31));

    for (let i = 0; i < LANES; i += 5) {
      H[i] = H[i] ^ d0h; L[i] = L[i] ^ d0l;
    }
    for (let i = 1; i < LANES; i += 5) {
      H[i] = H[i] ^ d1h; L[i] = L[i] ^ d1l;
    }
    for (let i = 2; i < LANES; i += 5) {
      H[i] = H[i] ^ d2h; L[i] = L[i] ^ d2l;
    }
    for (let i = 3; i < LANES; i += 5) {
      H[i] = H[i] ^ d3h; L[i] = L[i] ^ d3l;
    }
    for (let i = 4; i < LANES; i += 5) {
      H[i] = H[i] ^ d4h; L[i] = L[i] ^ d4l;
    }

    // ---------------- ρ + π（手工展开，B[y][(2x+3y)%5] = rot(A[x][y], r[x][y])）----------------
    BH[0] = H[0]; BL[0] = L[0];                                                     // rot  0
    BH[10] = (H[1] << 1) | (L[1] >>> 31); BL[10] = (L[1] << 1) | (H[1] >>> 31);     // rot  1
    BH[20] = (L[2] << 30) | (H[2] >>> 2); BL[20] = (H[2] << 30) | (L[2] >>> 2);     // rot 62
    BH[5] = (H[3] << 28) | (L[3] >>> 4); BL[5] = (L[3] << 28) | (H[3] >>> 4);       // rot 28
    BH[15] = (H[4] << 27) | (L[4] >>> 5); BL[15] = (L[4] << 27) | (H[4] >>> 5);     // rot 27
    BH[16] = (L[5] << 4) | (H[5] >>> 28); BL[16] = (H[5] << 4) | (L[5] >>> 28);     // rot 36
    BH[1] = (L[6] << 12) | (H[6] >>> 20); BL[1] = (H[6] << 12) | (L[6] >>> 20);     // rot 44
    BH[11] = (H[7] << 6) | (L[7] >>> 26); BL[11] = (L[7] << 6) | (H[7] >>> 26);     // rot  6
    BH[21] = (L[8] << 23) | (H[8] >>> 9); BL[21] = (H[8] << 23) | (L[8] >>> 9);     // rot 55
    BH[6] = (H[9] << 20) | (L[9] >>> 12); BL[6] = (L[9] << 20) | (H[9] >>> 12);     // rot 20
    BH[7] = (H[10] << 3) | (L[10] >>> 29); BL[7] = (L[10] << 3) | (H[10] >>> 29);   // rot  3
    BH[17] = (H[11] << 10) | (L[11] >>> 22); BL[17] = (L[11] << 10) | (H[11] >>> 22); // rot 10
    BH[2] = (L[12] << 11) | (H[12] >>> 21); BL[2] = (H[12] << 11) | (L[12] >>> 21); // rot 43
    BH[12] = (H[13] << 25) | (L[13] >>> 7); BL[12] = (L[13] << 25) | (H[13] >>> 7); // rot 25
    BH[22] = (L[14] << 7) | (H[14] >>> 25); BL[22] = (H[14] << 7) | (L[14] >>> 25); // rot 39
    BH[23] = (L[15] << 9) | (H[15] >>> 23); BL[23] = (H[15] << 9) | (L[15] >>> 23); // rot 41
    BH[8] = (L[16] << 13) | (H[16] >>> 19); BL[8] = (H[16] << 13) | (L[16] >>> 19); // rot 45
    BH[18] = (H[17] << 15) | (L[17] >>> 17); BL[18] = (L[17] << 15) | (H[17] >>> 17); // rot 15
    BH[3] = (H[18] << 21) | (L[18] >>> 11); BL[3] = (L[18] << 21) | (H[18] >>> 11); // rot 21
    BH[13] = (H[19] << 8) | (L[19] >>> 24); BL[13] = (L[19] << 8) | (H[19] >>> 24); // rot  8
    BH[14] = (H[20] << 18) | (L[20] >>> 14); BL[14] = (L[20] << 18) | (H[20] >>> 14); // rot 18
    BH[24] = (H[21] << 2) | (L[21] >>> 30); BL[24] = (L[21] << 2) | (H[21] >>> 30); // rot  2
    BH[9] = (L[22] << 29) | (H[22] >>> 3); BL[9] = (H[22] << 29) | (L[22] >>> 3);   // rot 61
    BH[19] = (L[23] << 24) | (H[23] >>> 8); BL[19] = (H[23] << 24) | (L[23] >>> 8); // rot 56
    BH[4] = (H[24] << 14) | (L[24] >>> 18); BL[4] = (L[24] << 14) | (H[24] >>> 18); // rot 14

    // ---------------- χ ----------------
    H[0] = BH[0] ^ (~BH[1] & BH[2]); L[0] = BL[0] ^ (~BL[1] & BL[2]);
    H[1] = BH[1] ^ (~BH[2] & BH[3]); L[1] = BL[1] ^ (~BL[2] & BL[3]);
    H[2] = BH[2] ^ (~BH[3] & BH[4]); L[2] = BL[2] ^ (~BL[3] & BL[4]);
    H[3] = BH[3] ^ (~BH[4] & BH[0]); L[3] = BL[3] ^ (~BL[4] & BL[0]);
    H[4] = BH[4] ^ (~BH[0] & BH[1]); L[4] = BL[4] ^ (~BL[0] & BL[1]);
    H[5] = BH[5] ^ (~BH[6] & BH[7]); L[5] = BL[5] ^ (~BL[6] & BL[7]);
    H[6] = BH[6] ^ (~BH[7] & BH[8]); L[6] = BL[6] ^ (~BL[7] & BL[8]);
    H[7] = BH[7] ^ (~BH[8] & BH[9]); L[7] = BL[7] ^ (~BL[8] & BL[9]);
    H[8] = BH[8] ^ (~BH[9] & BH[5]); L[8] = BL[8] ^ (~BL[9] & BL[5]);
    H[9] = BH[9] ^ (~BH[5] & BH[6]); L[9] = BL[9] ^ (~BL[5] & BL[6]);
    H[10] = BH[10] ^ (~BH[11] & BH[12]); L[10] = BL[10] ^ (~BL[11] & BL[12]);
    H[11] = BH[11] ^ (~BH[12] & BH[13]); L[11] = BL[11] ^ (~BL[12] & BL[13]);
    H[12] = BH[12] ^ (~BH[13] & BH[14]); L[12] = BL[12] ^ (~BL[13] & BL[14]);
    H[13] = BH[13] ^ (~BH[14] & BH[10]); L[13] = BL[13] ^ (~BL[14] & BL[10]);
    H[14] = BH[14] ^ (~BH[10] & BH[11]); L[14] = BL[14] ^ (~BL[10] & BL[11]);
    H[15] = BH[15] ^ (~BH[16] & BH[17]); L[15] = BL[15] ^ (~BL[16] & BL[17]);
    H[16] = BH[16] ^ (~BH[17] & BH[18]); L[16] = BL[16] ^ (~BL[17] & BL[18]);
    H[17] = BH[17] ^ (~BH[18] & BH[19]); L[17] = BL[17] ^ (~BL[18] & BL[19]);
    H[18] = BH[18] ^ (~BH[19] & BH[15]); L[18] = BL[18] ^ (~BL[19] & BL[15]);
    H[19] = BH[19] ^ (~BH[15] & BH[16]); L[19] = BL[19] ^ (~BL[15] & BL[16]);
    H[20] = BH[20] ^ (~BH[21] & BH[22]); L[20] = BL[20] ^ (~BL[21] & BL[22]);
    H[21] = BH[21] ^ (~BH[22] & BH[23]); L[21] = BL[21] ^ (~BL[22] & BL[23]);
    H[22] = BH[22] ^ (~BH[23] & BH[24]); L[22] = BL[22] ^ (~BL[23] & BL[24]);
    H[23] = BH[23] ^ (~BH[24] & BH[20]); L[23] = BL[23] ^ (~BL[24] & BL[20]);
    H[24] = BH[24] ^ (~BH[20] & BH[21]); L[24] = BL[24] ^ (~BL[20] & BL[21]);

    // ---------------- ι ----------------
    H[0] = H[0] ^ RC_H[r];
    L[0] = L[0] ^ RC_L[r];
  }
}

export class DeepSeekHash {
  private static enc: util.TextEncoder = new util.TextEncoder();

  /** 通用入口：任意长度输入 → 32 字节摘要 */
  static hashString(msg: string): Uint8Array {
    return DeepSeekHash.hashBytes(DeepSeekHash.enc.encode(msg));
  }

  static hashBytes(data: Uint8Array): Uint8Array {
    const H: Int32Array = new Int32Array(LANES);
    const L: Int32Array = new Int32Array(LANES);
    const BH: Int32Array = new Int32Array(LANES);
    const BL: Int32Array = new Int32Array(LANES);
    let off: number = 0;
    const n: number = data.length;
    while (off + RATE <= n) {
      DeepSeekHash.absorb(H, L, BH, BL, data, off);
      off += RATE;
    }
    const blk: Uint8Array = new Uint8Array(RATE);
    const tail: number = n - off;
    for (let i = 0; i < tail; i++) {
      blk[i] = data[off + i];
    }
    blk[tail] = 0x06;
    blk[RATE - 1] = blk[RATE - 1] | 0x80;
    DeepSeekHash.absorb(H, L, BH, BL, blk, 0);
    return DeepSeekHash.squeeze(H, L);
  }

  private static absorb(H: Int32Array, L: Int32Array, BH: Int32Array, BL: Int32Array,
    b: Uint8Array, off: number): void {
    for (let i = 0; i < 17; i++) {
      const o: number = off + i * 8;
      const lo: number = b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
      const hi: number = b[o + 4] | (b[o + 5] << 8) | (b[o + 6] << 16) | (b[o + 7] << 24);
      H[i] = H[i] ^ hi;
      L[i] = L[i] ^ lo;
    }
    permute(H, L, BH, BL);
  }

  private static squeeze(H: Int32Array, L: Int32Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(32);
    for (let i = 0; i < 4; i++) {
      const lo: number = L[i] >>> 0;
      const hi: number = H[i] >>> 0;
      out[i * 8 + 0] = lo & 0xff;
      out[i * 8 + 1] = (lo >>> 8) & 0xff;
      out[i * 8 + 2] = (lo >>> 16) & 0xff;
      out[i * 8 + 3] = (lo >>> 24) & 0xff;
      out[i * 8 + 4] = hi & 0xff;
      out[i * 8 + 5] = (hi >>> 8) & 0xff;
      out[i * 8 + 6] = (hi >>> 16) & 0xff;
      out[i * 8 + 7] = (hi >>> 24) & 0xff;
    }
    return out;
  }

  static toHex(d: Uint8Array): string {
    let s: string = '';
    for (let i = 0; i < d.length; i++) {
      const h: string = d[i].toString(16);
      s += h.length === 1 ? '0' + h : h;
    }
    return s;
  }

  /**
   * 内置自检：用一条真实抓到的 challenge / answer 校验哈希实现
   * （与墙钟时间无关，可永久作为回归用例）
   */
  static selfTest(): boolean {
    const d: Uint8Array =
      DeepSeekHash.hashString('82a875dd6f0757241fed_1789207715395_11747');
    const hex: string = DeepSeekHash.toHex(d);
    const ok: boolean =
      hex === 'ccfdd5b03a194eaacdfd7678b083a68aa3968f2406841c0ceaeff97ef935758e';
    hilog.info(0x0001, TAG, 'selfTest=%{public}s hex=%{public}s',
      ok ? 'PASS' : 'FAIL', hex);
    return ok;
  }

  /**
   * PoW 求解：搜索 nonce ∈ [0, difficulty) 使 hash(prefix + nonce) == challenge
   *
   * @param prefix 形如 "<salt>_<expire_at>_"（调用方拼好）
   * @param challengeHex 64 字符 hex
   * @param difficulty 搜索上界（同时是搜索范围，不是"前 N 位为 0"）
   * @param budgetMs 时间预算，超时返回 -1
   * @param onProgress 每片回调（已尝试次数, 总搜索范围）
   */
  /**
   * 在 [from, to) 区间内同步搜索 nonce，命中返回 nonce，否则 -1
   *
 * ⚠️ 纯计算、不 yield、不 await —— **必须跑在后台线程**。
 *    在主线程上连续调用会触发 THREAD_BLOCK_6S，系统直接杀死进程
 *    （实测：手表上即使每 1500 次让出一次，仍被判定阻塞）。
 *    调度交给 PowTask.ets 的 taskpool。
   */
  static searchRange(prefix: string, challengeHex: string, from: number, to: number): number {
    if (challengeHex.length !== 64 || to <= from) {
      return -1;
    }
    // 目标：4 个 lane 的 hi/lo
    // ⚠️ 坑：challenge 是 64 字符 hex，每 2 字符 = 1 字节（大端书写）。
    //    lane 的低 32 位 = bytes[0..3] 的**小端**组合，
    //    不能直接 parseInt(hex.substring(0,8), 16)（那是大端数，字节序正好反了）。
    const tb: Int32Array = new Int32Array(32);
    for (let i = 0; i < 32; i++) {
      tb[i] = parseInt(challengeHex.substring(i * 2, i * 2 + 2), 16);
    }
    const t0l: number = (tb[0] | (tb[1] << 8) | (tb[2] << 16) | (tb[3] << 24)) >>> 0;
    const t0h: number = (tb[4] | (tb[5] << 8) | (tb[6] << 16) | (tb[7] << 24)) >>> 0;
    const t1l: number = (tb[8] | (tb[9] << 8) | (tb[10] << 16) | (tb[11] << 24)) >>> 0;
    const t1h: number = (tb[12] | (tb[13] << 8) | (tb[14] << 16) | (tb[15] << 24)) >>> 0;
    const t2l: number = (tb[16] | (tb[17] << 8) | (tb[18] << 16) | (tb[19] << 24)) >>> 0;
    const t2h: number = (tb[20] | (tb[21] << 8) | (tb[22] << 16) | (tb[23] << 24)) >>> 0;
    const t3l: number = (tb[24] | (tb[25] << 8) | (tb[26] << 16) | (tb[27] << 24)) >>> 0;
    const t3h: number = (tb[28] | (tb[29] << 8) | (tb[30] << 16) | (tb[31] << 24)) >>> 0;

    const pBytes: Uint8Array = DeepSeekHash.enc.encode(prefix);
    const r: number = pBytes.length;
    // 单块快路径要求：前缀 + 最多 7 位 nonce + 1 字节 0x06 必须塞进 136 字节
    if (r + 8 > RATE - 1) {
      return DeepSeekHash.searchRangeSlow(prefix, challengeHex, from, to);
    }

    const blk: Uint8Array = new Uint8Array(RATE);
    for (let i = 0; i < r; i++) {
      blk[i] = pBytes[i];
    }
    blk[RATE - 1] = 0x80;

    // 模板 lane（nonce 区为 0、无 0x06）
    const tplH: Int32Array = new Int32Array(LANES);
    const tplL: Int32Array = new Int32Array(LANES);
    DeepSeekHash.lanesOf(blk, r, tplH, tplL);

    const H: Int32Array = new Int32Array(LANES);
    const L: Int32Array = new Int32Array(LANES);
    const BH: Int32Array = new Int32Array(LANES);
    const BL: Int32Array = new Int32Array(LANES);

    const laneLo: number = r >> 3;
    const laneHi: number = (r + 7) >> 3;

    for (let n = from; n < to; n++) {
      // --- 写 nonce 十进制 + 0x06 ---
      let d: number;
      if (n < 10) {
        d = 1;
      } else if (n < 100) {
        d = 2;
      } else if (n < 1000) {
        d = 3;
      } else if (n < 10000) {
        d = 4;
      } else if (n < 100000) {
        d = 5;
      } else if (n < 1000000) {
        d = 6;
      } else {
        d = 7;
      }
      let tmp: number = n;
      for (let k = d - 1; k >= 0; k--) {
        blk[r + k] = 48 + (tmp % 10);
        tmp = Math.floor(tmp / 10);
      }
      blk[r + d] = 0x06;

      // --- 恢复前缀状态（只有受 nonce 影响的 lane 需要重算）---
      for (let i = 0; i < LANES; i++) {
        H[i] = tplH[i]; L[i] = tplL[i];
      }
      for (let ln = laneLo; ln <= laneHi; ln++) {
        const o: number = ln * 8;
        const lo: number = blk[o] | (blk[o + 1] << 8) | (blk[o + 2] << 16) | (blk[o + 3] << 24);
        const hi: number = blk[o + 4] | (blk[o + 5] << 8) | (blk[o + 6] << 16) | (blk[o + 7] << 24);
        // 单块吸收：状态初值为 0，故 lane 直接取块的完整 lane 值（前缀+nonce+0x06）
        H[ln] = hi;
        L[ln] = lo;
      }

      permute(H, L, BH, BL);

      if ((L[0] >>> 0) === t0l && (H[0] >>> 0) === t0h &&
        (L[1] >>> 0) === t1l && (H[1] >>> 0) === t1h &&
        (L[2] >>> 0) === t2l && (H[2] >>> 0) === t2h &&
        (L[3] >>> 0) === t3l && (H[3] >>> 0) === t3h) {
        return n;
      }
    }
    return -1;
  }

  /** 超长前缀的区间搜索兜底（每次完整哈希，慢，正常不会走到） */
  private static searchRangeSlow(prefix: string, challengeHex: string,
    from: number, to: number): number {
    for (let n = from; n < to; n++) {
      if (DeepSeekHash.toHex(DeepSeekHash.hashString(prefix + n.toString())) === challengeHex) {
        return n;
      }
    }
    return -1;
  }

  /**
   * 主线程版求解：分片调用 searchRange，片间让出。
   *
   * ⚠️ 仅用于 Node 回归测试与兜底。**手表上不要走这里** ——
   *    实测即使每 1500 次让出一次，系统仍报 THREAD_BLOCK_6S 并杀进程。
   *    真机请走 PowSolver → taskpool（PowTask.ets）。
   */
  static async solve(prefix: string, challengeHex: string, difficulty: number,
    budgetMs: number, onProgress?: (tried: number, total: number) => void): Promise<number> {
    if (challengeHex.length !== 64 || difficulty <= 0) {
      hilog.error(0x0001, TAG, 'pow bad args len=%{public}d diff=%{public}d',
        challengeHex.length, difficulty);
      return -1;
    }
    hilog.info(0x0001, TAG, 'pow start prefix=%{public}s challenge=%{public}s diff=%{public}d',
      prefix, challengeHex, difficulty);
    const SLICE: number = 1500;
    const start: number = Date.now();
    for (let from = 0; from < difficulty; from += SLICE) {
      const to: number = Math.min(difficulty, from + SLICE);
      const hit: number = DeepSeekHash.searchRange(prefix, challengeHex, from, to);
      if (hit >= 0) {
        hilog.info(0x0001, TAG, 'pow solved answer=%{public}d tried=%{public}d ms=%{public}d',
          hit, hit, Date.now() - start);
        return hit;
      }
      if (onProgress) {
        onProgress(to, difficulty);
      }
      if (Date.now() - start > budgetMs) {
        hilog.warn(0x0001, TAG, 'pow timeout tried=%{public}d', to);
        return -1;
      }
      await DeepSeekHash.yield_();
    }
    hilog.warn(0x0001, TAG, 'pow exhausted difficulty=%{public}d', difficulty);
    return -1;
  }

  /** 计算 blk 中前 17 个 lane（用于模板） */
  private static lanesOf(blk: Uint8Array, len: number, outH: Int32Array, outL: Int32Array): void {
    for (let i = 0; i < 17; i++) {
      const o: number = i * 8;
      outH[i] = blk[o + 4] | (blk[o + 5] << 8) | (blk[o + 6] << 16) | (blk[o + 7] << 24);
      outL[i] = blk[o] | (blk[o + 1] << 8) | (blk[o + 2] << 16) | (blk[o + 3] << 24);
    }
  }

  private static yield_(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 0);
    });
  }
}
