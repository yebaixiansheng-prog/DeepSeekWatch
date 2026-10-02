/**
 * 应用配置（设置页读写）
 *
 * ★ 2026-09-30 新写，替代旧的 AuthService（那是网页版登录态管理，已删除）。
 *   官方 API 只需要：一个密钥 + 模型 + 两个开关。
 */

import { Store, Keys } from '../common/Store';
import { ApiKey, Model, Thinking } from '../common/Constants';

export class AppConfig {
  /** 内存缓存，避免每次发消息都读一次 Preferences（省电） */
  private static key: string = '';
  private static modelV: string = Model.FLASH;
  private static thinkingV: boolean = false;
  private static searchV: boolean = false;
  private static loaded: boolean = false;

  /** 冷启动加载一次 */
  static async load(): Promise<void> {
    if (AppConfig.loaded) {
      return;
    }
    const k: string = await Store.get(Keys.API_KEY, '');
    // 用户没覆盖过 → 用内置密钥
    AppConfig.key = k.length > 0 ? k : ApiKey.BUILTIN;

    const m: string = await Store.get(Keys.MODEL, '');
    AppConfig.modelV = m.length > 0 ? m : Model.FLASH;

    AppConfig.thinkingV = (await Store.get(Keys.THINKING, '0')) === '1';
    AppConfig.searchV = (await Store.get(Keys.SEARCH, '0')) === '1';

    AppConfig.loaded = true;
  }

  static apiKey(): string {
    return AppConfig.key.length > 0 ? AppConfig.key : ApiKey.BUILTIN;
  }

  /** 密钥是否已就绪（内置也算就绪） */
  static hasKey(): boolean {
    return AppConfig.apiKey().length > 0;
  }

  static async setApiKey(v: string): Promise<void> {
    AppConfig.key = v.trim();
    await Store.put(Keys.API_KEY, AppConfig.key);
  }

  static model(): string {
    return AppConfig.modelV;
  }

  static async setModel(v: string): Promise<void> {
    AppConfig.modelV = v;
    await Store.put(Keys.MODEL, v);
  }

  static thinking(): boolean {
    return AppConfig.thinkingV;
  }

  static async setThinking(v: boolean): Promise<void> {
    AppConfig.thinkingV = v;
    await Store.put(Keys.THINKING, v ? '1' : '0');
  }

  static search(): boolean {
    return AppConfig.searchV;
  }

  static async setSearch(v: boolean): Promise<void> {
    AppConfig.searchV = v;
    await Store.put(Keys.SEARCH, v ? '1' : '0');
  }

  /** 思考模式的描述（设置页展示用） */
  static thinkingLabel(): string {
    return AppConfig.thinkingV ? '已开启（回答更准，但更慢）' : '已关闭（响应更快）';
  }

  /** 搜索的描述 */
  static searchLabel(): string {
    return AppConfig.searchV ? '已开启（需要时自动联网）' : '已关闭';
  }

  static modelLabel(): string {
    return Model.label(AppConfig.modelV);
  }

  /** 开关的字符串值（给 UI 用的统一出口） */
  static thinkingType(): string {
    return AppConfig.thinkingV ? Thinking.ON : Thinking.OFF;
  }
}
