# ゲーミングカレンダー

複数のゲームのイベント・ガチャの終了日時をまとめて確認し、「いつの間にか終わっていた」を防ぐためのPWAです。

- 終了が近い順のリスト表示（24時間以内 / 3日以内 / 7日以内）とタイムライン表示
- イベントごとの「完了」チェック、不要なお知らせの「非表示」
- 手動でのイベント追加（どのゲームでも可）
- 終了の3日前・1日前・3時間前のブラウザ通知
- Googleカレンダー連携（`calendar.ics` の購読、または個別追加）

## 手元で動かす

```powershell
powershell -ExecutionPolicy Bypass -File scripts/serve.ps1
```

http://localhost:8123/ を開きます。

イベント情報を最新にするには：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-events.ps1
```

## 公開して自動更新する（GitHub Pages）

1. このフォルダをGitHubリポジトリとして公開する
2. Settings → Pages で、ブランチのルートを公開元に設定する
3. Settings → Actions → General → Workflow permissions を「Read and write」にする

`.github/workflows/update-events.yml` が6時間ごとにイベントを取得し、`data/events.json` と `calendar.ics` を更新します。
公開後、アプリの「設定」に表示されるURLをGoogleカレンダーの「URLで追加」に貼ると購読できます。

## ゲームを追加する

`data/games.json` の `games` に追記します。取得元タイプは次の3つです。

| type | 対象 | 取得方法 |
| --- | --- | --- |
| `hoyoverse` | 原神 / スターレイル / ゼンゼロ | ゲーム内お知らせAPI |
| `monst` | モンスト | 公式サイトのお知らせ記事から開催期間を抽出 |
| `pad` | パズドラ | 公式運営サイトの特設ページから開催期間を抽出 |
| `articles` | ブルアカ / ウマ娘 / FGO / アークナイツ / グラブル / ポケモンGO / にゃんこ大戦争 | 公式のお知らせ一覧（HTMLのリンク、またはJSON API）を読み、各記事から開催期間を抽出 |
| `sekai` | プロセカ | 有志が公開しているマスターデータ（sekai-world）のイベント・ガチャ日程 |

`articles` は設定だけで増やせます。HTML一覧なら `listUrls` と `linkPattern`、JSON APIなら `rows`・`id`・`title`・`date` と、本文の場所（`content`、または `detailUrl` + `detailPath`）を指定します。
「11/16 12:00 ～ 12/21 11:59」のように曜日なしで期間を書くサイトは `"loose": true` を付けます。

別の取得元を増やす場合は `scripts/fetch-events.ps1` の `switch ($game.source.type)` に分岐を追加してください。
`recurring` には、お知らせに載らない毎月リセットのコンテンツ（深境螺旋・幻想シアター）を日付ルールで登録しています。

## 種類分けと「石がもらえる」判定

- 種類（`categories`）は、タイトルに対する正規表現ルール（`rules`、ゲーム別 → `defaults` の順で最初に一致したもの）で決まります。
- 💎（`reward`）は、「高難度・定期」に分類されたもの、またはお知らせ本文に各ゲームの `currency`（原石・オーブ・魔法石など）が出てくるものに付きます。あくまで目安です。
- `exclude` に一致したお知らせは取り込みません。いずれも `defaults` をゲームごとに上書きできます。
`fetch-events.ps1` 自体はASCIIのみで保つこと（Windows PowerShell 5.1 がBOMなしUTF-8を誤読するため）。
