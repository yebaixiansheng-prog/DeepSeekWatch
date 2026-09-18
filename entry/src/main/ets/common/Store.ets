import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';

const TAG: string = 'Store';

/** `getChecked` 的返回：value 为空串时，用 ok 区分「确实没值」与「没读到」 */
export interface StoreRead {
  ok: boolean;
  value: string;
}

/**
 * 本地轻量存储：登录态、设置、会话缓存
 * 使用 Preferences（手表端比关系型库更省电）
 *
 * ⚠️ 两个必须守住的点（都是实机踩过的）：
 *   1. 初始化可能**偶发失败**。旧实现在失败后 `pref` 永久为 null，
 *      随后所有 get 都返回默认值 → `AuthService.restore()` 拿到空 token
 *      → 用户明明登录过，冷启动却看到登录页，且**没有任何重试机会**。
 *      现在把 ctx 留着，任何一次读写都会尝试补初始化。
 *   2. `isReady()` 用于让 UI 区分「确实没登录」和「存储读不出来」，
 *      后者不该把用户引导去打密码。
 */
export class Store {
  private static pref: preferences.Preferences | null = null;
  private static ctx: common.UIAbilityContext | null = null;
  private static readonly NAME: string = 'dswatch_store';
  /** 初始化中的 Promise（防并发重复初始化） */
  private static initing: Promise<void> | null = null;

  static async init(ctx: common.UIAbilityContext): Promise<void> {
    Store.ctx = ctx;
    if (Store.pref !== null) {
      return;
    }
    if (Store.initing !== null) {
      await Store.initing;
      return;
    }
    Store.initing = new Promise<void>((resolve: () => void) => {
      preferences.getPreferences(ctx, Store.NAME)
        .then((p: preferences.Preferences) => {
          Store.pref = p;
          Store.initing = null;
          resolve();
        })
        .catch(() => {
          // 不清 ctx：留待下次读写时重试
          Store.initing = null;
          resolve();
        });
    });
    await Store.initing;
  }

  /**
   * 确保存储可用；必要时补一次初始化
   * @returns 是否可用
   */
  private static async ready(): Promise<boolean> {
    if (Store.pref !== null) {
      return true;
    }
    if (Store.ctx === null) {
      return false;
    }
    await Store.init(Store.ctx);
    return Store.pref !== null;
  }

  static isReady(): boolean {
    return Store.pref !== null;
  }

  static async put(key: string, value: string): Promise<void> {
    if (!(await Store.ready())) {
      return;
    }
    const p: preferences.Preferences = Store.pref as preferences.Preferences;
    // ⚠️ put/flush 也可能抛（磁盘满、句柄被回收、并发写冲突）。
    //    不 catch 会变成 unhandled rejection，在部分固件上直接崩进程；
    //    更糟的是调用方 await 它会连带失败，把「登录成功但存不下 token」
    //    这种可恢复问题升级成「登录流程整个失败」。
    //    存储失败不该阻断主流程 —— 记一条 warn，让上层继续走。
    try {
      await p.put(key, value);
      await p.flush();
    } catch (e) {
      hilog.warn(0x0001, TAG, 'put(%{public}s) failed: %{public}s',
        key, JSON.stringify(e));
    }
  }

  static async get(key: string, def: string = ''): Promise<string> {
    if (!(await Store.ready())) {
      return def;
    }
    const p: preferences.Preferences = Store.pref as preferences.Preferences;
    try {
      const v = await p.get(key, def);
      return v as string;
    } catch (e) {
      hilog.warn(0x0001, TAG, 'get(%{public}s) failed: %{public}s',
        key, JSON.stringify(e));
      return def;
    }
  }

  /**
   * 读取一个 key，并**区分**「读到空值」与「读取失败」
   *
   * ★ 为什么需要这个 API（登录态相关的 key 必须用它）：
   *   `get()` 在读失败时会返回默认值（空串），这与「用户确实没登录」
   *   在调用方看来**完全一样**。于是存储偶发故障会表现成
   *   「明明登录过，冷启动却回到登录页」—— 正是本类要防的那个坑。
   *   需要区分时用这个：`ok=false` 表示**没读到**，不代表值是空的，
   *   此时应引导「重试」而不是让用户重新打密码。
   */
  static async getChecked(key: string): Promise<StoreRead> {
    if (!(await Store.ready())) {
      return { ok: false, value: '' };
    }
    const p: preferences.Preferences = Store.pref as preferences.Preferences;
    try {
      const v = await p.get(key, '');
      return { ok: true, value: v as string };
    } catch (e) {
      hilog.warn(0x0001, TAG, 'getChecked(%{public}s) failed: %{public}s',
        key, JSON.stringify(e));
      return { ok: false, value: '' };
    }
  }

  static async remove(key: string): Promise<void> {
    if (!(await Store.ready())) {
      return;
    }
    const p: preferences.Preferences = Store.pref as preferences.Preferences;
    try {
      await p.delete(key);
      await p.flush();
    } catch (e) {
      hilog.warn(0x0001, TAG, 'remove(%{public}s) failed: %{public}s',
        key, JSON.stringify(e));
    }
  }
}

/** 存储 key */
export class Keys {
  static readonly TOKEN: string = 'token';
  static readonly USER: string = 'user_json';
  static readonly DEVICE_ID: string = 'device_id';
  static readonly FONT_SCALE: string = 'font_scale';
  static readonly LAST_MODE: string = 'last_mode';
  static readonly AUTO_THINK: string = 'auto_think';
  static readonly AUTO_SEARCH: string = 'auto_search';
  static readonly LAST_SESSION: string = 'last_session_id';
}
