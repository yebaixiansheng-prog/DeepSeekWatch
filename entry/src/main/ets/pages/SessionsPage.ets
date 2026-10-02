/**
 * 会话列表页（历史对话）
 *
 * ★ 2026-10-03 重构（用户要求「统一视觉风格、按 y 计算宽度」）
 *   本次改动：
 *     · 配色全部走 Theme 令牌（去掉 15 处字面色值）；
 *     · 列表项宽度从写死 84% 改为**按该项的 y 计算** ——
 *       84%（=391px）只在屏幕中部成立，底部几项会被圆弧切掉；
 *     · 显示每条对话**绑定的人设**（用户要求「一眼看懂」）。
 *
 * 圆屏约束（来自实测）：
 *   · y=415 物理弦宽 291px，y=428 弦宽 255px，y=450 弦宽 170px。
 *   · y≥450 是系统手势区，可点元素下沿必须 ≤ 436。
 *   · 列表底部要留够滚动余量，否则最后一项滚不到可点区域。
 */

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo, Round, Unit } from '../common/RoundScreen';
import { Color, Radius, Space, Touch } from '../common/Theme';
import { ChatStore, personaBadge } from '../model/ChatStore';
import { Persona, PersonaStore } from '../model/Persona';
import { Keys } from '../common/Store';
import { Store } from '../common/Store';

interface SessionRow {
  id: string;
  title: string;
  time: string;
  count: number;
  /** 绑定的人设名（空串 = 未绑定） */
  persona: string;
}

@Entry
@Component
struct SessionsPage {
  @State rows: SessionRow[] = [];
  @State loading: boolean = true;

  async aboutToAppear(): Promise<void> {
    await this.reload();
  }

  private async reload(): Promise<void> {
    // ★ 先失效缓存：对话页可能刚保存了新消息/新标题，
    //   不清缓存这里读到的是上一份快照 ——
    //   表现为「刚聊完的对话，回历史列表看到的还是旧标题」。
    ChatStore.invalidate();
    const idx = await ChatStore.index();
    // ★ 人设名一次性查出来（不要在循环里 await，20 条会话 = 20 次读）
    const personaMap = new Map<string, string>();
    const all: Persona[] = await PersonaStore.all();
    for (const p of all) {
      personaMap.set(p.id, personaBadge(p));
    }

    const out: SessionRow[] = [];
    for (const e of idx) {
      out.push({
        id: e.id,
        title: e.title.length > 0 ? e.title : '新对话',
        time: fmtTime(e.updatedAt),
        count: e.count,
        // 人设被删了 → map 里查不到 → 显示「人设已删除」，
        // 而不是留空（留空会让用户以为这条对话本来就没绑人设）
        persona: e.personaId.length === 0
          ? ''
          : (personaMap.has(e.personaId) ? (personaMap.get(e.personaId) as string) : '人设已删除')
      });
    }
    this.rows = out;
    this.loading = false;
  }

  private async open(id: string): Promise<void> {
    await Store.put(Keys.LAST_SESSION, id);
    // 返回对话页；对话页 aboutToAppear 会读 LAST_SESSION 并加载
    router.back();
  }

  private confirmDelete(id: string, title: string): void {
    promptAction.showDialog({
      title: '删除这条对话？',
      message: '「' + title + '」将被永久删除。',
      buttons: [
        { text: '取消', color: Color.textSub },
        { text: '删除', color: Color.danger }
      ]
    }).then(async (r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 1) {
        await ChatStore.remove(id);
        await this.reload();
        promptAction.showToast({ message: '已删除', duration: 1000 });
      }
    }).catch(() => {
    });
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('‹ 返回')
          .fontSize(Typo.caption)
          .fontColor(Color.textSub)
          .onClick(() => router.back())
        Blank()
        Text('历史对话')
          .fontSize(Typo.caption)
          .fontColor(Color.text)
        Blank()
        Text('　　')
          .fontSize(Typo.caption)
      }
      .width(Round.bottomUsableVp(Y_BAR - Touch.barH / 2, 6))
      .height(Touch.barH)
      .margin({ top: Y_BAR - Touch.barH / 2 })

      if (this.loading) {
        Text('加载中…')
          .fontSize(Typo.caption)
          .fontColor(Color.textFaint)
          .margin({ top: 20 })
      } else if (this.rows.length === 0) {
        Column() {
          Text('还没有历史对话')
            .fontSize(Typo.body)
            .fontColor(Color.textFaint)
          Text('回到对话页发一条消息就会出现在这里')
            .fontSize(Typo.caption - 2)
            .fontColor(Color.textGhost)
            .textAlign(TextAlign.Center)
            .margin({ top: 4 })
        }
        .width(Round.bottomUsableVp(Y_EMPTY, 6))
        .margin({ top: 24 })
      } else {
        List() {
          ForEach(this.rows, (r: SessionRow, i: number) => {
            ListItem() {
              Row() {
                Column() {
                  Row() {
                    Text(r.title)
                      .fontSize(Typo.body)
                      .fontColor(Color.text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    // ★ 人设标签：用户要求「一眼看懂这条对话跟谁聊的」
                    if (r.persona.length > 0) {
                      Text(r.persona)
                        .fontSize(Typo.caption - 4)
                        .fontColor(Color.primaryText)
                        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                        .borderRadius(Radius.chip)
                        .backgroundColor(Color.primaryDim)
                        .maxLines(1)
                        .margin({ left: Space.xs })
                    }
                  }
                  .width('100%')

                  Text(r.time + ' · ' + r.count.toString() + ' 条')
                    .fontSize(Typo.caption - 2)
                    .fontColor(Color.textFaint)
                    .maxLines(1)
                    .margin({ top: 1 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('✕')
                  .fontSize(Typo.caption)
                  .fontColor(Color.textFaint)
                  .textAlign(TextAlign.Center)
                  .width(32)
                  .height(32)
                  .borderRadius(16)
                  .backgroundColor(Color.surfaceSunken)
                  .onClick(() => this.confirmDelete(r.id, r.title))
              }
              .width(rowWidthVp(i))
              .height(Touch.rowH)
              .padding({ left: 12, right: 8 })
              .borderRadius(Radius.card)
              .backgroundColor(Color.surface)
              .onClick(() => this.open(r.id))
            }
            .width('100%')
          }, (r: SessionRow) => r.id + '_' + r.time)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // ★ 底部留白：让最后一条能滚出手势区（y≥450 点不到）。
        //   滚到底时最后一项位于「屏幕底 - 留白」，留白必须 ≥ 手势区高度，
        //   否则用户滚到底反而点不到最后一条 —— 这是最气人的交互。
        .padding({ bottom: Unit.px2vp(Round.screenH - Round.comfortBottomPx) + Space.lg })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
    .backgroundColor(Color.bg)
    .borderRadius('50%')
    .clip(true)
  }
}

// ========================================================================
//  布局
// ========================================================================

/** 顶栏中心 y（vp） */
const Y_BAR: number = 22;
/** 列表内容上沿（vp） */
const Y_LIST_TOP: number = 8;
/** 空态文案的 y（vp） */
const Y_EMPTY: number = 90;

/**
 * 第 i 行的宽度（vp）—— 按该项的 y 计算
 *
 * ★ 为什么按 index 估算就够了：本页列表最多 30 项（MAX_SESSIONS），
 *   用静态布局估算位置已经比「写死 84%」精确得多，而且**安全方向**
 *   （估算出来的 y 偏下 → 宽度偏窄 → 不会切角）。
 *   真要逐像素精确需要 List 的 onScrollIndex + 每项 onAreaChange，
 *   在手表上是浪费电。
 */
function rowWidthVp(i: number): number {
  const topY: number = Y_BAR + Touch.barH / 2 + Y_LIST_TOP + i * (Touch.rowH + Space.sm);
  return Round.bottomUsableVp(topY, 6);
}

function fmtTime(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const d: Date = new Date(ts);
  const now: Date = new Date();
  const sameDay: boolean = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  const hh: string = pad(d.getHours());
  const mm: string = pad(d.getMinutes());
  if (sameDay) {
    return hh + ':' + mm;
  }
  return (d.getMonth() + 1).toString() + '/' + d.getDate().toString() + ' ' + hh + ':' + mm;
}

function pad(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}
