/**
 * 人设管理页
 *
 * ★ 2026-10-03 新增（用户需求：「新增 AI 人设创建与管理功能」）
 *
 * ## 两个模式（同页切换，不新开路由）
 *
 *   LIST  —— 人设列表：每条显示名称 + 摘要，底部「新建」，右侧进编辑
 *   EDIT  —— 编辑一条：五个字段（名称 + 四个自定义维度）+ 保存/删除
 *
 * 为什么用一个页面两个模式而不是两个路由：
 *   · 手表上 `router.pushUrl` 有肉眼可见的白屏（页面重建）；
 *   · 编辑完「返回」要刷新列表 —— 同页模式下就是改一个 `@State`，零成本；
 *   · 圆屏页面本来就少，路由栈太深会让用户迷失。
 *
 * ## 输入态的特殊处理（★ 血泪教训）
 *
 * 本机输入法是 `bounds=[0,0][466,466]` 的**全屏窗口，会完全盖住 App**。
 * 所以编辑页在输入时：
 *   · **不能**放「收起键盘」按钮 —— 它虽被渲染却**既看不见也点不到**；
 *   · 收键盘的唯一途径是系统 `key Back`；
 *   · 因此每个字段必须**失焦即自动保存**（`onBlur` → `saveCurrent`），
 *     否则用户收完键盘才发现没保存，得靠记忆重进。
 *
 * ## 字号与圆屏
 *
 * 列表项宽度按各自 `y` 走 `Round.bottomUsableVp` 计算（用户明确要求），
 * 编辑页的文本框同理 —— 底部那个字段最容易被圆弧切掉，必须按 y 收。
 */

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, Round, Unit, FontScale } from '../common/RoundScreen';
import { Color, Radius, Space, Touch, Motion } from '../common/Theme';
import { Store, Keys } from '../common/Store';
import {
  Persona, PersonaField, PERSONA_FIELDS, FieldMeta, NAME_MAX_LEN, MAX_PERSONAS,
  PersonaStore, newPersona, withField, readField, validatePersona,
  isBlank, summaryOf
} from '../model/Persona';
import { RoundButton, RoundScrollBody } from '../components/RoundWidgets';

/** 页面模式 */
enum Mode {
  LIST = 0,
  EDIT = 1
}

@Entry
@Component
struct PersonaPage {
  @State mode: Mode = Mode.LIST;
  @State list: Persona[] = [];
  /** 编辑中的草稿（编辑态唯一数据源；保存时整体写入） */
  @State draft: Persona | null = null;
  /** 当前聚焦的字段 key（'' = 没有） */
  @State focusKey: string = '';
  @State errMsg: string = '';
  /** ★ 由调用方携带的「选人设」意图：从会话页进来时是 true，
   *  此时点列表项 = 选中并返回，而不是进入编辑。 */
  @State pickMode: boolean = false;
  /** 列表数据版本（配合 ForEach key，保证增删改后一定重绘） */
  @State rev: number = 0;

  private inputCtl: TextInputController = new TextInputController();
  /** 编辑框里的实时文本（不直接进 draft，避免每个字符都触发整页重绘） */
  @State editText: string = '';

  // ★ 生命周期方法**不能加 private** —— 它在 CustomComponent 基类里是
  //   公开成员，子类收窄可见性会被 ArkTS 判为「incorrectly extends」。
  async aboutToAppear(): Promise<void> {
    // 路由参数：pick=1 表示「选人设」模式
    this.pickMode = readPickMode();
    await this.reload();
  }
  private async reload(): Promise<void> {
    PersonaStore.invalidate();
    this.list = await PersonaStore.all();
    this.rev++;
  }

  // ======================================================================
  //  列表操作
  // ======================================================================

  /** 列表项点击：选人设模式 → 返回结果；普通模式 → 进编辑 */
  private async onRowTap(p: Persona): Promise<void> {
    if (this.pickMode) {
      // 约定：写两个 key 再 back。
      //   LAST_PERSONA    —— 长期记忆（下次新建对话的默认选中项）
      //   PENDING_PERSONA —— 一次性回传，对方读走即清（见 Keys 注释）
      await Store.put(Keys.LAST_PERSONA, p.id);
      await Store.put(Keys.PENDING_PERSONA, p.id);
      router.back();
      return;
    }
    // 进编辑
    this.draft = clonePersona(p);
    this.mode = Mode.EDIT;
    this.errMsg = '';
  }

  /** 新建 */
  private async onNew(): Promise<void> {
    if (this.list.length >= MAX_PERSONAS) {
      promptAction.showToast({
        message: '最多 ' + MAX_PERSONAS.toString() + ' 条人设',
        duration: 1600
      });
      return;
    }
    const p: Persona = newPersona(this.list);
    this.draft = p;
    this.mode = Mode.EDIT;
    this.errMsg = '';
    this.focusKey = '';
  }

  // ======================================================================
  //  编辑操作
  // ======================================================================

  /**
   * 开始编辑某个字段（点输入框）
   *
   * ★ 为什么不用 `TextInput` 的 `onFocus` 直接改状态：
   *   全屏输入法弹出时 App 会被完全覆盖，`onFocus` 之后到 `onBlur`
   *   之间这一屏是**用户看不到的**，任何"顺便做点事"都白做。
   *   所以这里只记录 focusKey，真正的保存动作放在 `onBlur`（见下）。
   */
  private beginEdit(key: string): void {
    const d: Persona | null = this.draft;
    if (d === null) {
      return;
    }
    this.focusKey = key;
    // ★ 用局部变量 `d` 而不是反复 `this.draft`：
    //   ArkTS 的窄化分析**不跨属性访问**，写
    //   `this.draft !== null ? readField(this.draft, key) : ...`
    //   会被判成 `Property 'name' does not exist on type 'never'`
    //   （它把 false 分支的 `this.draft` 也当成 null 处理，
    //    再取 .name 就成了对 never 取属性）。
    //   赋给局部常量后窄化就成立了。
    this.editText = readField(d, key);
  }

  /**
   * 字段失焦 → **落进 draft**（不落盘）
   *
   * 不落盘的理由：用户可能只是点错了框，或者想继续改别的字段。
   * 真正的持久化在「保存」按钮 / 返回时。
   * 但 draft 必须更新，否则「改完 A 再改 B 再点保存」会丢掉 A。
   */
  private commitField(): void {
    if (this.draft === null || this.focusKey.length === 0) {
      return;
    }
    this.draft = withField(this.draft, this.focusKey, this.editText);
    this.focusKey = '';
  }

  /** 保存到存储 */
  private async saveCurrent(): Promise<void> {
    // ★ 先结算正在编辑的字段 —— 否则用户"改完直接点保存"会丢最后一次输入
    this.commitField();
    const p: Persona | null = this.draft;
    if (p === null) {
      return;
    }
    const errs: string[] = validatePersona(p);
    if (errs.length > 0) {
      this.errMsg = errs[0];
      return;
    }
    const okSave: boolean = await PersonaStore.save(p);
    if (!okSave) {
      this.errMsg = '保存失败：已达人设数量上限';
      return;
    }
    this.errMsg = '';
    await this.reload();
    promptAction.showToast({ message: '已保存', duration: 1200 });
    this.mode = Mode.LIST;
  }

  /** 删除当前编辑的人设 */
  private async deleteCurrent(): Promise<void> {
    const p: Persona | null = this.draft;
    if (p === null) {
      return;
    }
    promptAction.showDialog({
      title: '删除这条人设？',
      message: '「' + (p.name.length > 0 ? p.name : '未命名') + '」将被删除。',
      buttons: [
        { text: '取消', color: Color.textSub },
        { text: '删除', color: Color.danger }
      ]
    }).then(async (r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        await PersonaStore.remove(p.id);
        await this.reload();
        this.mode = Mode.LIST;
        this.draft = null;
        promptAction.showToast({ message: '已删除', duration: 1000 });
      }
    }).catch(() => {
    });
  }

  // ======================================================================
  //  UI —— 列表
  // ======================================================================

  @Builder
  ListView() {
    Column() {
      this.TopBar('人设', this.pickMode ? '选择' : '')

      if (this.list.length === 0) {
        Column() {
          Text('还没有人设')
            .fontSize(Typo.body)
            .fontColor(Color.textFaint)
        }
        .width('76%')
        .margin({ top: 30 })
      } else {
        Scroll() {
          Column({ space: Space.sm }) {
            ForEach(this.list, (p: Persona, i: number) => {
              this.RowItem(p, i)
            }, (p: Persona, i: number) => p.id + '_' + this.rev.toString())
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: Space.sm, bottom: 40 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      // 底部：新建
      if (!this.pickMode) {
        RoundButton({
          label: '＋ 新建人设',
          primary: false,
          heightVp: Touch.hMd,
          onTap: () => this.onNew()
        })
          .margin({ bottom: Space.md })
          .flexShrink(0)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 列表项
   *
   * ★ 宽度按**该项所在的 y** 计算（用户明确要求「全部换成按 y 计算」）。
   *   列表是滚动的，为什么还能按 y 算？
   *   因为圆屏列表的可用宽度只取决于**它此刻画在屏幕上的位置**。
   *   ArkUI 的 List 有虚拟化，但本项目人设最多 20 条，
   *   实际渲染的就是静态位置 —— 用 index 估算 y 足够，
   *   而且**比写死 84% 好得多**：写死会让底部几项被圆弧切掉。
   *
   *   估算方式：顶栏下端 + index × (行高 + 间距)。
   */
  @Builder
  RowItem(p: Persona, i: number) {
    Row() {
      Column() {
        Row() {
          Text(p.name.length > 0 ? p.name : '未命名')
            .fontSize(Typo.body)
            .fontColor(Color.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (p.builtin) {
            Text('内置')
              .fontSize(Typo.caption - 4)
              .fontColor(Color.primaryText)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(Radius.chip)
              .backgroundColor(Color.primaryDim)
              .margin({ left: 4 })
          }
        }
        .width('100%')

        Text(summaryOf(p))
          .fontSize(Typo.caption - 2)
          .fontColor(isBlank(p) ? Color.textGhost : Color.textSub)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.pickMode ? '›' : '✎')
        .fontSize(Typo.caption)
        .fontColor(Color.textGhost)
        .margin({ left: Space.xs })
    }
    .width(this.rowWidthVp(i))
    .height(Touch.rowH)
    .padding({ left: 12, right: 12 })
    .borderRadius(Radius.card)
    .backgroundColor(Color.surface)
    .onClick(() => this.onRowTap(p))
  }

  /** 列表项宽度：按估算的 y 位置收窄 */
  private rowWidthVp(i: number): number {
    const topY: number = Y_TOPBAR + Y_LIST_TOP + i * (Touch.rowH + Space.sm);
    const centerY: number = topY + Touch.rowH / 2;
    return Round.bottomUsableVp(centerY - Touch.rowH / 2, 6);
  }

  // ======================================================================
  //  UI —— 编辑
  // ======================================================================

  @Builder
  EditView() {
    Column() {
      this.TopBar('编辑人设', '')

      Scroll() {
        Column({ space: Space.md }) {
          // ---------- 名称 ----------
          this.FieldBlock(PersonaField.NAME, '名称',
            '例如：严谨助手', NAME_MAX_LEN, 0)

          // ---------- 四个自定义维度 ----------
          ForEach(PERSONA_FIELDS, (f: FieldMeta, i: number) => {
            this.FieldBlock(f.key, f.label, f.hint, f.maxLen, i + 1)
          }, (f: FieldMeta) => f.key)

          if (this.errMsg.length > 0) {
            Text(this.errMsg)
              .fontSize(Typo.caption - 1)
              .fontColor(Color.danger)
              .textAlign(TextAlign.Center)
              .width('76%')
              .maxLines(2)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: Space.sm, bottom: 44 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // ---------- 底部：保存 / 删除 ----------
      Row({ space: Space.sm }) {
        if (this.draft !== null) {
          Button('删除')
            .type(ButtonType.Capsule)
            .height(Touch.hMd)
            .layoutWeight(1)
            .fontSize(Typo.body)
            .fontColor(Color.danger)
            .backgroundColor(Color.dangerDim)
            .onClick(() => this.deleteCurrent())

          Button('保存')
            .type(ButtonType.Capsule)
            .height(Touch.hMd)
            .layoutWeight(1)
            .fontSize(Typo.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.onPrimary)
            .backgroundColor(Color.primary)
            .onClick(() => this.saveCurrent())
        }
      }
      .width(this.bottomRowWidthVp())
      .margin({ bottom: Space.md })
      .flexShrink(0)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 一个字段块：标签 + 说明 + 可点击的输入框
   *
   * ★★ 交互三重纪律（全屏输入法导致）：
   *   1. 显示态用 `Text` 而**不是**常驻 `TextInput` ——
   *      5 个常驻 TextInput 在圆屏上会各自渲染光标并抢焦点，
   *      而且用户点哪个都只是弹全屏输入法，根本看不见输入框。
   *   2. 点击 → `beginEdit` → `focus()` 主动拉起输入法。
   *   3. `onBlur` → `commitField` 结算。用户按系统 Back 收键盘时，
   *      blob 一定会触发（这是收键盘的唯一途径，实测过）。
   *
   * @param order 0 = 名称，1..4 = 四个维度（用于估算 y 算宽度）
   */
  @Builder
  FieldBlock(key: string, label: string, hint: string, maxLen: number, order: number) {
    Column() {
      Row() {
        Text(label)
          .fontSize(Typo.caption)
          .fontColor(Color.textSub)
          .layoutWeight(1)
        Text(this.lenOf(key).toString() + '/' + maxLen.toString())
          .fontSize(Typo.caption - 3)
          .fontColor(this.lenOf(key) > maxLen ? Color.danger : Color.textGhost)
      }
      .width('100%')

      if (this.focusKey === key) {
        // ---------- 编辑态：真正的输入框 ----------
        TextInput({ text: this.editText, placeholder: hint, controller: this.inputCtl })
          .id('field_' + key)
          .enterKeyType(EnterKeyType.Done)
          .fontSize(Typo.body)
          .fontColor(Color.text)
          .placeholderColor(Color.textGhost)
          .backgroundColor(Color.surfaceSunken)
          .borderRadius(Radius.chip)
          .height(Touch.hMd)
          .width('100%')
          .padding({ left: 10, right: 10 })
          .caretColor(Color.primary)
          .selectedBackgroundColor(Color.primaryDim)
          .onChange((v: string) => {
            this.editText = v;
          })
          .onSubmit(() => {
            this.commitField();
          })
          .onBlur(() => {
            this.commitField();
          })
      } else {
        // ---------- 显示态：可点的文本块（省资源、也不会抢焦点） ----------
        Text(this.displayOf(key))
          .fontSize(Typo.body)
          .fontColor(this.displayOf(key).length > 0 ? Color.text : Color.textGhost)
          .width('100%')
          .constraintSize({ minHeight: Touch.hSm })
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(Radius.chip)
          .backgroundColor(Color.surfaceSunken)
          .onClick(() => this.beginEdit(key))
      }
    }
    .width(this.fieldWidthVp(order))
    .alignItems(HorizontalAlign.Start)
  }

  /** 把 draft 里该字段的值取出来做实时字数统计 */
  private lenOf(key: string): number {
    return this.focusKey === key
      ? this.editText.length
      : (this.draft !== null ? readField(this.draft, key).length : 0);
  }

  /** 显示态文本 */
  private displayOf(key: string): string {
    if (this.draft === null) {
      return '';
    }
    const v: string = readField(this.draft, key);
    return v.length > 0 ? v : '点击填写';
  }

  /**
   * 字段块的宽度（vp）—— 按它在页面上的估算 y 收窄
   *
   * 不用 `blockPct(区域最窄处)` 的原因：编辑页是**可滚动**的，
   * 一屏只能放下 2~3 个字段，每个字段的实际渲染位置取决于滚动。
   * 这里按「不滚动时的静态布局」估算 —— 比写死 84% 好得多
   * （写死会让最下面那个字段在滚动到该位置时被切掉）。
   */
  private fieldWidthVp(order: number): number {
    const topY: number = Y_TOPBAR + Y_EDIT_TOP + order * (FIELD_BLOCK_H + Space.md);
    const centerY: number = topY + FIELD_BLOCK_H / 2;
    return Round.bottomUsableVp(centerY - FIELD_BLOCK_H / 2, 6);
  }

  /** 底部按钮行的宽度（按它的 y 算） */
  private bottomRowWidthVp(): number {
    const topY: number = Unit.px2vp(Round.screenH) - Space.md - Touch.hMd;
    return Round.bottomUsableVp(topY, 6);
  }

  // ======================================================================
  //  公共 UI
  // ======================================================================

  @Builder
  TopBar(title: string, hint: string) {
    Row() {
      Text('‹ 返回')
        .fontSize(Typo.caption)
        .fontColor(Color.textSub)
        .onClick(() => {
          if (this.mode === Mode.EDIT) {
            // 编辑态返回：先结算字段，再回列表（不落盘 —— 用户没点保存）
            this.commitField();
            this.mode = Mode.LIST;
            this.draft = null;
            this.errMsg = '';
          } else {
            goBack();
          }
        })
      Blank()
      Text(title)
        .fontSize(Typo.caption)
        .fontColor(Color.text)
      Blank()
      Text(hint.length > 0 ? hint : '　　')
        .fontSize(Typo.caption - 1)
        .fontColor(Color.primaryText)
    }
    .width(this.topBarWidthVp())
    .height(Touch.barH)
    .alignItems(VerticalAlign.Center)
  }

  private topBarWidthVp(): number {
    return Round.bottomUsableVp(Y_TOPBAR - Touch.barH / 2, 6);
  }

  // ======================================================================

  build() {
    Column() {
      if (this.mode === Mode.EDIT) {
        this.EditView()
      } else {
        this.ListView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.bg)
    .borderRadius('50%')
    .clip(true)
  }
}

// ========================================================================
//  布局常量（页面级，用于按 y 估算宽度）
// ========================================================================

/** 顶栏中心 y（vp）—— 圆屏顶部安全区从约 14vp 开始 */
const Y_TOPBAR: number = 22;
/** 列表内容区上沿（vp） */
const Y_LIST_TOP: number = 8;
/** 编辑页内容区上沿（vp） */
const Y_EDIT_TOP: number = 8;
/** 一个字段块的高度（vp）＝ 标签行 + 输入块 */
const FIELD_BLOCK_H: number = Touch.hMd + 18;

// ========================================================================
//  工具函数
// ========================================================================

/** 深拷贝（防止编辑草稿时改到列表里的同一对象） */
function clonePersona(p: Persona): Persona {
  return {
    id: p.id,
    name: p.name,
    personality: p.personality,
    background: p.background,
    tone: p.tone,
    replyStyle: p.replyStyle,
    createdAt: p.createdAt,
    builtin: p.builtin
  };
}

/**
 * ★ 读路由参数：是否为「选人设」模式
 *
 * `router.getParams()` 在**没有参数**时返回 `undefined`，
 * 直接取属性会崩。这里统一兜底。
 *
 * ★ 为什么用 `String(...)` 而不是 `=== '1'` 直接比：
 *   路由参数经 JSON 序列化后类型可能变成 number（传 `{pick: 1}` 时）。
 *   统一转字符串再比，两种写法都能work —— 调用方不用记住该传哪种。
 */
function readPickMode(): boolean {
  try {
    const p = router.getParams() as Record<string, Object>;
    if (p === undefined || p === null) {
      return false;
    }
    return String(p['pick']) === '1';
  } catch (e) {
    return false;
  }
}

function goBack(): void {
  router.back();
}
