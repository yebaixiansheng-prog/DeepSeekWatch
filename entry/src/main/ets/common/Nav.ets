/**
 * 页面间一次性传参
 *
 * 为什么不用 router.back({url, params})：
 *   - `back()` 携带的参数只能通过目标页的 `router.getParams()` 读取，
 *     而目标页 `aboutToAppear` 已经跑过了，需要靠 `onPageShow` 二次读取，
 *     在部分 ArkUI 版本上时序不稳定（曾出现「点了会话但页面没换」）。
 *   - 这里改成「写一个静态槽位 → 目标页 onPageShow 主动取走」，
 *     语义清晰、时序确定，也不受路由栈长度影响。
 *
 * 使用约定：
 *   历史页点击会话 → Nav.selectSession(id) → router.back()
 *   历史页点「新对话」→ Nav.selectNewChat() → router.back()
 *   对话页 onPageShow → const p = Nav.takePending()，非 null 就按它切换
 */
export class Nav {
  /** 待处理的目标会话 id（空串 = 新对话） */
  private static pendingId: string = '';
  /** 是否有待处理的选择（区分「没选」与「选了新对话」） */
  private static pending: boolean = false;

  /** 选中某个历史会话 */
  static selectSession(id: string): void {
    Nav.pendingId = id;
    Nav.pending = true;
  }

  /** 要求对话页开一个新对话 */
  static selectNewChat(): void {
    Nav.pendingId = '';
    Nav.pending = true;
  }

  /**
   * 取走待处理的选择（取走即清空，保证只生效一次）
   * @returns null 表示没有待处理选择；'' 表示要开新对话；其它为会话 id
   */
  static takePending(): string | null {
    if (!Nav.pending) {
      return null;
    }
    Nav.pending = false;
    const id: string = Nav.pendingId;
    Nav.pendingId = '';
    return id;
  }

  /** 丢弃待处理选择（例如未登录、加载失败时） */
  static reset(): void {
    Nav.pending = false;
    Nav.pendingId = '';
  }
}
