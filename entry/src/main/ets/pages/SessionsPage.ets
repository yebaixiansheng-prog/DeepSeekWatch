/**
 * 会话列表页（历史对话）
 *
 * ★ 2026-09-30 推倒重来后新写（替代旧的 HistoryPage，那个是拉服务端会话列表的）。
 *   官方 API 无云端会话，列表来自本地 ChatStore。
 *
 * 圆屏约束：列表项宽度 84%（≈391px），这个宽度在 y ≤ 415 区域才安全；
 * 本页内容从顶部开始排（justifyContent: Start），往下滚动由用户控制，
 * 所以不做逐行宽度收窄 —— 但**底部最后一项要留出滚动余量**，
 * 避免最后一项被手势区挡住点不到（用 padding bottom 解决）。
 */

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Typo } from '../common/RoundScreen';
import { ChatStore } from '../model/ChatStore';
import { Keys } from '../common/Store';
import { Store } from '../common/Store';

interface SessionRow {
  id: string;
  title: string;
  time: string;
  count: number;
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
    const idx = await ChatStore.index();
    const out: SessionRow[] = [];
    for (const e of idx) {
      out.push({
        id: e.id,
        title: e.title.length > 0 ? e.title : '新对话',
        time: fmtTime(e.updatedAt),
        count: e.count
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
        { text: '取消', color: '#8A8F9A' },
        { text: '删除', color: '#FF6B6B' }
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
          .fontColor('#8A8F9A')
          .onClick(() => router.back())
        Blank()
        Text('历史对话')
          .fontSize(Typo.caption)
          .fontColor('#E8EAED')
        Blank()
        Text('　　')
          .fontSize(Typo.caption)
      }
      .width('80%')
      .height(30)
      .margin({ top: 8 })

      if (this.loading) {
        Text('加载中…')
          .fontSize(Typo.caption)
          .fontColor('#5A5F6B')
          .margin({ top: 20 })
      } else if (this.rows.length === 0) {
        Column() {
          Text('还没有历史对话')
            .fontSize(Typo.body)
            .fontColor('#5A5F6B')
          Text('回到对话页发一条消息就会出现在这里')
            .fontSize(Typo.caption - 2)
            .fontColor('#3E434E')
            .textAlign(TextAlign.Center)
            .margin({ top: 4 })
        }
        .width('76%')
        .margin({ top: 24 })
      } else {
        List() {
          ForEach(this.rows, (r: SessionRow) => {
            ListItem() {
              Row() {
                Column() {
                  Text(r.title)
                    .fontSize(Typo.body)
                    .fontColor('#E8EAED')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(r.time + ' · ' + r.count.toString() + ' 条')
                    .fontSize(Typo.caption - 2)
                    .fontColor('#5A5F6B')
                    .maxLines(1)
                    .margin({ top: 1 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('✕')
                  .fontSize(Typo.caption)
                  .fontColor('#5A5F6B')
                  .textAlign(TextAlign.Center)
                  .width(32)
                  .height(32)
                  .borderRadius(16)
                  .backgroundColor('#1A1C22')
                  .onClick(() => this.confirmDelete(r.id, r.title))
              }
              .width('100%')
              .height(50)
              .padding({ left: 12, right: 8 })
              .borderRadius(12)
              .backgroundColor('#12141A')
              .onClick(() => this.open(r.id))
            }
            .width('100%')
          }, (r: SessionRow) => r.id + '_' + r.time)
        }
        .width('84%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // ★ 底部留白：让最后一条能滚出手势区（y≥450 点不到）
        .padding({ bottom: 46 })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#000000')
    .borderRadius('50%')
    .clip(true)
  }
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
