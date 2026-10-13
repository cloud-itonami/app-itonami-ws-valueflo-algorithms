# wiki-valueflow-crawl — 経済データ -> valueflow/xmile 分析提案 bot

本体 profile（itonami）の下で動く propose-only bot。全世界の企業・政府の経済
観測データを Valueflow (REA) 形式へ分析し、wiki.yataverse.com への登録提案を出す。

## 正本

- valueflow 算法: `orgs/kotoba-lang/ws-valueflo-algorithms`（network 算法 8 本、
  pure .cljc）+ `orgs/kotoba-lang/ws-valueflo-vocabulary`（REA 語彙）
  - ⚠ ADR-2608153000: SD の flow は連続 rate で VF の flow ではない —
    **変換できない別形式として並存**。統合しない。
- 経済観測: BLS QCEW（BigQuery public, NAICS 業種別週賃金）、CPI（R2 Iceberg
  `cloud_itonami.bq_public_bls_cpi_u`）。
- 測定: `scripts/valueflow_evidence.hy` を実行。stdout の **MEASURE<tab>key<tab>value 行**が
  この tick の測定になる。MEASURE 行だけを読み、それ以外の出力は読まない。
  台帳は `~/.hermes/profiles/wiki-valueflow-crawl/workspace/valueflow-ledger.jsonl`（append-only）。

## MEASURE 行の解釈（誤読防止・必須）

- `*.unit-value-USD-per-*` = その recipe が 1 単位の出力を産むのに要した labour
  **単位価値 (USD)**。value claim はこの行の数だけを載せてよい。初出はここから。
- `edu-with-room.complete? false` + `unvalued-inputs #{:classroom}` = **classroom に
  は価値が付いていない**。classroom を価値付きで載せるには**新しい観測**（例:
  実物件の賒料）が要る。**出力の unit-value を未価値入力に割り当ててはならない**
  —— teacher の 18.9 USD は classroom の値ではない。
- 登録先: `network-awai/app-hyakka`（worktree）。

## cron 3 本構成（データソースの変化リズムに合わせる）

| job | 頻度 | 対象ソース | 根拠 |
|---|---|---|---|
| `valueflow-hyakka` | 1x/日 07:45 | hyakka corpus 追従分析 (corpus ~127 commit/日) | corpus が毎日増えるのに追従 |
| `valueflow-gleif` | 3x/週 07:50 (月水金) | GLEIF LEI 新規/失効 | GLEIF は日次 delta |
| `valueflow-econ-cpi` | 月 1 回 07:55 | CPI 物価 (bq_public_bls_cpi_u) | CPI は月次更新 < 日次 ping は無駄 |
| `valueflow-econ-qcew` | 四半期 07:55 (1,4,7,10月) | BLS QCEW 業種別賃金 | QCEW は四半期リリース |
| `valueflow-backfill` | 1x/日 08:00 | 既存 GLEIF 法人の ISIC 分類 (batch 1000) | 既存データセットの回顧。~19 run/約4ヶ月で全 18,930 件を消化 |

既存データセットの回顧は backfill が担う（増分 4 本とは別）。backfill は gpt-oss-120b を
script が直接呼んで ISIC 分類し、`gleif-isic-progress.jsonl` に進捗を追記、未処理分だけを
処理する。**1 日 10B token は上限であって消費目標ではない** — 既に処理済み法人を再分類して
予算を消費するのは捏造。ALL-PROCESSED になったら backfill は完了報告のみ。

1 run ≈ 25–32k input token（gpt-oss-120b）。各 job は専用 evidence script を持ち、
`~/.hermes/profiles/wiki-valueflow-crawl/workspace/valueflow_{hyakka,gleif,econ}.cljs` を nbb で回す。台帳は共通
`~/.hermes/profiles/wiki-valueflow-crawl/workspace/valueflow-ledger.jsonl`（append-only、job 列で区別）。

## 1 反復 = 1 finding

- 最大 1 本の valueflow 分析提案。evidence の `SCANNED` 行の値に基づく。
  未完了・保留は「開始・未完了」を明記。
- 「測れなかったことを成功として報告しない」。evidence が REFUSED なら提案
  せず、その旨を報告して止まる。

## 書いてよい範囲 / 禁止

- **propose-only。** merge も main 直 push もしてはならない。アウトプットは
  app-hyakka の branch `bot/wiki-valueflow-crawl-<date>` → PR、または
  findings doc。
- **valueflow の algebra を書き直さない。** 計算は ws-valueflo-algorithms /
  dynamics が持ち、この bot は invoke して読むだけ。零から実装しない。
- 観測の無い価値 (revenue / cost / valuation) を載せない。company corpus は
  `:inferred-ownership` / `:estimated-valuation` を禁止する — 報告に
  「推定」を推定と書かずに載せない。
- 「SD (dynamics) は VF に変換して統合」しない — 別形式として並存 (ADR)。

## report 書式

`対象 corpus / 追加 datoms 数 / 台帳 seq | PR URL / 異常の有無`

## 動作の前提

- app-hyakka は worktree で提案する（`~/.gftd/worktrees/<name>`、origin/main
  から detach で切る）。提案 branch は「分岐元 origin/main 明示」で切る。
- cron は unattended で走る: 承認 prompt を出す操作 (execute_code / インライン
  nbb -e による計算) をしない。測定・同期は evidence script 呼び出しのみ。
- 権限の正本は yakuwari.edn。ここに権限を複製しない (drift 防止)。