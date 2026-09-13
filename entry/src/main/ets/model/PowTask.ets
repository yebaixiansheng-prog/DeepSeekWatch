import taskpool from '@ohos.taskpool';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { DeepSeekHash } from '../common/DeepSeekHash';
import { NativeHash } from './NativeHash';

const TAG: string = 'PowTask';

/**
 * 在后台线程搜索 [from, to) 区间的 PoW nonce（ArkTS 回退实现）
 *
 * @Concurrent 的硬约束（踩过的坑）
 * ------------------------------------------------------------------
 * - ❌ 不能捕获外部变量（闭包），只能用参数传入 —— 所以四个参数全显式传递
 * - ❌ 不能返回 Promise / 不能是 async
 * - ✅ 可以调用其他模块导出的函数（DeepSeekHash.searchRange）
 */
@Concurrent
function powRange(prefix: string, challengeHex: string, from: number, to: number): number {
  return DeepSeekHash.searchRange(prefix, challengeHex, from, to);
}

/**
 * ArkTS 回退路径的并行度：同时丢给线程池的区间数
 *
 * ⚠️ 真机实测（HUAWEI WATCH 5）：这条路径只有约 1000~2000 次哈希/秒，
 *    一次难度 144000 的 PoW 要 20~55 秒 —— 只在原生模块不可用时才会走到。
 */
const WORKERS: number = 3;

/** 单个 worker 每轮负责的 nonce 区间长度 */
const RANGE_PER_WORKER: number = 12000;

/**
 * 原生路径每片 nonce 数
 *
 * 原生实现单片只要几毫秒；分片 + 片间让出主线程，
 * 是为了即使原生实现比预期慢很多也不会触发 THREAD_BLOCK_6S（主线程 6 秒无响应被强杀）。
 */
const NATIVE_CHUNK: number = 20000;

/**
 * 求解 PoW
 *
 * 两条路径：
 *   ① 原生（C++/NAPI）：自检通过时走这条，通常**几十毫秒**搜完整个区间；
 *   ② ArkTS（taskpool 多 worker）：原生不可用时的回退，慢但正确。
 *
 * @returns 命中的 nonce；-1 表示区间内没有解或超时
 */
export async function solvePowAsync(prefix: string, challengeHex: string,
  difficulty: number, budgetMs: number,
  onProgress?: (tried: number, total: number) => void): Promise<number> {
  const start: number = Date.now();

  // ================= ① 原生路径 =================
  if (NativeHash.isOk()) {
    try {
      for (let from = 0; from < difficulty; from += NATIVE_CHUNK) {
        const to: number = Math.min(difficulty, from + NATIVE_CHUNK);
        const hit: number = NativeHash.searchRange(prefix, challengeHex, from, to);
        if (hit >= 0) {
          hilog.info(0x0001, TAG, 'pow solved(native) answer=%{public}d tried=%{public}d ms=%{public}d',
            hit, hit, Date.now() - start);
          return hit;
        }
        if (onProgress) {
          onProgress(to, difficulty);
        }
        await PowTask_yieldMain();
        if (Date.now() - start > budgetMs) {
          hilog.warn(0x0001, TAG, 'pow timeout(native) tried=%{public}d', to);
          return -1;
        }
      }
      hilog.warn(0x0001, TAG, 'pow exhausted(native) difficulty=%{public}d', difficulty);
      return -1;
    } catch (e) {
      // 原生调用异常（极少数情况，例如 .so 加载失败）→ 落到 ArkTS 回退，保证还能用
      hilog.error(0x0001, TAG, 'native search failed, fallback to ArkTS: %{public}s',
        JSON.stringify(e));
    }
  }

  // ================= ② ArkTS 回退路径 =================
  const roundSize: number = WORKERS * RANGE_PER_WORKER;

  for (let base = 0; base < difficulty; base += roundSize) {
    const pending: Promise<Object>[] = [];
    let launched: number = 0;
    for (let w = 0; w < WORKERS; w++) {
      const from: number = base + w * RANGE_PER_WORKER;
      if (from >= difficulty) {
        break;
      }
      const to: number = Math.min(difficulty, from + RANGE_PER_WORKER);
      try {
        const task: taskpool.Task = new taskpool.Task(powRange, prefix, challengeHex, from, to);
        pending.push(taskpool.execute(task));
        launched++;
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0001, TAG, 'taskpool submit failed code=%{public}d msg=%{public}s',
          err.code, err.message);
      }
    }
    if (launched === 0) {
      hilog.error(0x0001, TAG, 'taskpool all submit failed');
      return -1;
    }

    for (let i = 0; i < pending.length; i++) {
      let hit: number = -1;
      try {
        hit = await pending[i] as number;
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0001, TAG, 'taskpool run failed code=%{public}d msg=%{public}s',
          err.code, err.message);
      }
      if (hit >= 0) {
        hilog.info(0x0001, TAG,
          'pow solved answer=%{public}d tried=%{public}d ms=%{public}d workers=%{public}d',
          hit, hit, Date.now() - start, WORKERS);
        return hit;
      }
    }

    const done: number = Math.min(difficulty, base + launched * RANGE_PER_WORKER);
    if (onProgress) {
      onProgress(done, difficulty);
    }
    if (Date.now() - start > budgetMs) {
      hilog.warn(0x0001, TAG, 'pow timeout tried=%{public}d', done);
      return -1;
    }
  }
  hilog.warn(0x0001, TAG, 'pow exhausted difficulty=%{public}d', difficulty);
  return -1;
}

/** 让出主线程一拍（原生分片之间调用，避免长时间占用主线程） */
function PowTask_yieldMain(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}
