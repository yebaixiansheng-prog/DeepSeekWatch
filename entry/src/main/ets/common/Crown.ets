/**
 * 旋转表冠（Digital Crown）交互封装
 *
 * HarmonyOS 手表使用 onDigitalCrown 事件感知表冠旋转（API 18+，仅 Wearable）：
 *   .focusable(true).defaultFocus(true).focusOnTouch(true)
 *   .onDigitalCrown((event: CrownEvent) => { ... })
 *
 * 本应用的使用约定（按用户需求）：
 *   - 登录页：旋转表冠 = 调节字号大小（圆形屏字体适配）
 *   - 对话页：旋转表冠 = 翻动上下文（滚动消息列表）
 *
 * 注意：Scroll / List / Slider 等组件**默认**已支持表冠滚动，
 *       自定义交互（如本应用的字号调节）才需要显式接管 onDigitalCrown。
 */

/** 旋转方向 */
export enum RotateDir {
  NONE = 0,
  CW = 1,   // 顺时针
  CCW = -1  // 逆时针
}

/** 表冠事件回调 */
export interface CrownHandlers {
  /** 旋转（delta > 0 顺时针） */
  onRotate?: (delta: number) => void;
  /** 按下表冠 */
  onPress?: () => void;
}

/**
 * 归一化表冠旋转量
 *
 * 输入来源：CrownEvent.degree（相对旋转角度，单位度，范围 [-360, 360]）
 * 手表表冠每次"咔哒"约转动 15~20 度，这里以 STEP 度为一个交互步，
 * 既不过灵敏也不过迟钝。
 */
export class Crown {
  /** 每触发一次的累积阈值（度） */
  private static readonly STEP: number = 18;
  private static acc: number = 0;
  /** 上一次事件的页签，用于识别「新一轮旋转」并清理残留累积 */
  private static lastTs: number = 0;
  /** 两次事件间隔超过该值视为新会话（毫秒） */
  private static readonly SESSION_GAP: number = 400;

  /**
   * 喂入原始角度，返回归一化步数
   * @param degree CrownEvent.degree（正=顺时针）
   * @returns 整数步数（正=顺时针）
   */
  static normalize(degree: number): number {
    if (degree === 0 || isNaN(degree)) {
      return 0;
    }
    // 长时间无事件 → 说明用户重新开始旋转，丢弃上次的零头
    const now: number = Date.now();
    if (now - Crown.lastTs > Crown.SESSION_GAP) {
      Crown.acc = 0;
    }
    Crown.lastTs = now;

    // 反方向旋转时先抵消残留累积，避免「回拧一点却继续朝原方向走」的粘滞感
    if (Crown.acc !== 0 && (Crown.acc > 0) !== (degree > 0)) {
      if (Math.abs(degree) >= Math.abs(Crown.acc)) {
        const rest: number = degree + Crown.acc;
        Crown.acc = 0;
        Crown.acc = rest;
      } else {
        Crown.acc += degree;
        return 0;
      }
    } else {
      Crown.acc += degree;
    }

    let steps: number = 0;
    // 限制单次最多 3 步，避免快速旋转时跳变过大
    while (Math.abs(Crown.acc) >= Crown.STEP && Math.abs(steps) < 3) {
      if (Crown.acc > 0) {
        steps += 1;
        Crown.acc -= Crown.STEP;
      } else {
        steps -= 1;
        Crown.acc += Crown.STEP;
      }
    }
    return steps;
  }

  /** 重置累积（切换页面 / 失焦时调用，避免跨页残留） */
  static reset(): void {
    Crown.acc = 0;
    Crown.lastTs = 0;
  }
}

/**
 * 字号调节器
 * 登录页/设置页用表冠调节字体大小（圆形屏可读性适配）
 */
export class FontTuner {
  /** 当前缩放 */
  value: number = 1.0;
  /** 下限 */
  min: number = 1.0;
  /** 上限 */
  max: number = 4.0;
  /** 每步缩放比例 */
  step: number = 0.15;

  constructor(min: number = 1.0, max: number = 4.0, step: number = 0.15) {
    this.min = min;
    this.max = max;
    this.step = step;
  }

  /** 顺时针放大，逆时针缩小 */
  rotate(steps: number): boolean {
    if (steps === 0) {
      return false;
    }
    const old: number = this.value;
    let v: number = this.value + steps * this.step;
    if (v < this.min) {
      v = this.min;
    }
    if (v > this.max) {
      v = this.max;
    }
    this.value = v;
    return Math.abs(old - v) > 0.0001;
  }

  /** 百分比文案 */
  percent(): string {
    return Math.round(this.value * 100).toString() + '%';
  }

  reset(): void {
    this.value = this.min;
  }
}

/**
 * 上下文翻页控制器
 * 对话页用表冠翻动消息
 */
export class ContextScroller {
  /** 当前滚动偏移（px） */
  offset: number = 0;
  /** 内容总高 */
  contentH: number = 0;
  /** 视口高 */
  viewH: number = 0;
  /** 每步滚动像素 */
  step: number = 48;

  /** 返回是否需要更新 */
  rotate(steps: number): boolean {
    if (steps === 0 || this.contentH <= this.viewH) {
      return false;
    }
    const max: number = this.contentH - this.viewH;
    const old: number = this.offset;
    let v: number = this.offset + steps * this.step;
    if (v < 0) {
      v = 0;
    }
    if (v > max) {
      v = max;
    }
    this.offset = v;
    return Math.abs(old - v) > 0.5;
  }

  /** 是否已到底（用于自动跟随最新） */
  atBottom(): boolean {
    if (this.contentH <= this.viewH) {
      return true;
    }
    return this.offset >= this.contentH - this.viewH - 4;
  }

  /** 跳到最新 */
  toBottom(): void {
    this.offset = Math.max(0, this.contentH - this.viewH);
  }
}
