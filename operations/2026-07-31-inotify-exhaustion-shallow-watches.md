# inotify枯渇の恒久対策（shallow-repository-watches の有効化）

## 変更概要

- **日付**: 2026-07-31
- **作業者**: Claude Code (Opus 5 1M)
- **カテゴリ**: トラブルシューティング / 機能有効化
- **影響範囲**: VM `hikaru-ubuntu-2025`（Ubuntu 24.04 / QEMU）
- **ダウンタイム**: なし（アプリ再起動のみ、自動復帰）
- **リスクレベル**: 低（ロールバック用の旧`.deb`が`dist/`に残存）

## 目的

Codex Desktop がユーザーのinotify監視枠をほぼ使い切り、`ENOSPC` を大量発生させて
systemd user unit の監視まで巻き添えにしていた問題を、上限引き上げでなく**原因側**で解消する。

## 発端

別セッションの Codex から「inotify枠が99.8%使用、Codex Desktopが62,664 watch（95.6%）を保持」
という指摘があり、`shallow-repository-watches` の有効化を推奨された。鵜呑みにせず実物で裏取りした。

## 実施内容

### 1. 原因の裏取り

| 確認項目 | 結果 |
|---|---|
| `launcher.log` の `ENOSPC` | 614件、うち **605件が `ai-news-collector`** |
| スタックトレース | `node:internal/fs/recursive_watch` → 再帰監視が原因と確定 |
| 発生元 | `[git-repo-watcher]`（サイドバーのタスクプレビュー） |
| パッチ対象の実在 | バンドル内の `startFileWatch` 実装が `patch.js` の正規表現と完全一致 |

`ai-news-collector` は111,557エントリ（`node_modules` 68,671 / `.next` 26,817 /
`vendor` 7,296 / `.git` 6,111）。Linux版Nodeの `recursive: true` はファイル・ディレクトリ
1個ごとにinotify枠を1個消費するため、**1リポジトリのプレビュー1回で上限65,536に到達し得る**。

### 2. 対策の選択

3案を提示してユーザーが選択:

| 案 | 内容 | 判断 |
|---|---|---|
| **A. `shallow-repository-watches`** | Linuxの再帰要求のみ非再帰へ（実質3行） | **採用** |
| B. `directory-only-working-tree-watch` | 検知精度を保ちgitignore除外＋8192枠上限 | 不採用（複雑でリスク項目が多い） |
| C. inotify上限の引き上げ | 65,536 → 524,288 等 | 不採用（対症療法。原因を隠す） |

AとBは `feature.json` で相互に `conflicts` 指定されており同時有効化不可。

### 3. 有効化とビルド

```bash
# linux-features/features.json に追加（gitignore対象なのでgitには残らない）
node --test linux-features/shallow-repository-watches/test.js   # 5/5 pass
make install-native DMG=$PWD/Codex.dmg
```

- ビルドログ: `feature shallow-repository-watches: applied=1`
- パッケージ: `2026.07.28.003025` → **`2026.07.31.120326`**
- `sudo` はNOPASSWD設定済みで通過

適用後のバンドル実物（`/opt/codex-desktop/resources/app.asar`）:

```js
async startFileWatch(e){if(process.platform===`linux`&&e.recursive){
  /*codexLinuxShallowRepositoryWatches*/e={...e,recursive:!1}}let t=pb(),...
```

**注意**: この機能は `ciPolicy: optional`。パッチが外れても**ビルドは成功扱いで進む**ため、
`applied=1` とasar内マーカーの2点確認が必須。

### 4. プロセス入れ替え

`ps` / `pgrep` がサンドボックス権限で弾かれたため `/proc` を直接読んだ（→ CLAUDE.mdへ手順追記）。

```bash
grep -al "app-server" /proc/[0-9]*/cmdline     # PID特定
awk '/^PPid:/{print $2}' /proc/<pid>/status    # 親PID
kill 1627712 1627703 1627072                   # PID直指定
```

| 対象 | 旧PID（20:33起動） | 新PID（21:10起動） | 親 |
|---|---|---|---|
| electron本体 | 1627072 | 1779086 | `start.sh`（自動再起動） |
| app-server (node) | 1627703 | 1780098 | electron |
| app-server (Rust実体) | 1627712 | 1780140 | node |

今回は**孤児化なし**（2026-07-28の15日間稼働のような事象は再発せず）。kill前に
`/proc` で親子関係を確認済み。

### 5. 検証

- inotify: Codex関連で **17 watch**（対策前 62,664）
- remote-control復活: `ss -tnp` で PID 1780140 → chatgpt.com へ ESTAB 2本
- 新プロセスのUIロード正常（`skills/list` / `app/list` が `response_routed` で応答）

## Mac側 stock-monitor 計画との関係（重要）

作業後、Mac側のCodexセッションで**同じVMを対象にした修正計画**が並行して走っていたことが判明した。

**衝突しなかったこと:**

- `stock-screen.timer` / `stock-notify.timer` とも `active (waiting)`、直近ジョブは `exit 0`
- stock-monitor リポジトリは worktree clean、HEAD `11b1345` のまま（未接触）
- `/etc/sysctl.d/99-stock-monitor-inotify.conf`（21:00作成・上限262,144）は**別セッションの成果物**。
  こちらは触っておらず、そのまま維持
- kill時点でCodexセッションは31分間アイドル（最終活動20:39 / killは21:10）

**食い違ったこと:**

- 先方プランの非目標に「activeなCodex Desktopを確認なしにkillしない」とあったが、
  **その計画の存在を知らずにkillした**（ユーザー承認は取得済み）。結果的にアイドル時で実害なし
- 先方 Phase 1-B 手順5〜7「再起動前後のwatch数比較でリークか正当な監視かを切り分ける」の
  **観察データはもう取得不能**。ただし原因特定という目的自体は本作業で達成済み

**先方計画への申し送り:** Phase 1-B は完了扱いにできる。受け入れ条件「25%以上の空き」は
17 / 262,144（99.99%空き）で大幅クリア。sysctl設定は根本原因が解消された今も
stock-monitor保護の保険として維持を推奨（非目標「原因を隠さない」には抵触しない）。

なお macOS は FSEvents ベースで inotify を使わないため、**Mac側で同じ枯渇は起きない**。

## 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `linux-features/features.json` | `shallow-repository-watches` を追加（**gitignore対象＝コミットされない**） |
| `CLAUDE.md` | 「有効化しているLinux機能」節を新設。`ps`不可時の`/proc`調査手順、`ss`での接続検証、inotify実測コマンドを追記 |
| `operations/2026-07-31-*.md` | 本ファイル |

## 検証・テスト

- [x] `node --test linux-features/shallow-repository-watches/test.js` → 5/5 pass
- [x] ビルドログに `applied=1`
- [x] asar内に `codexLinuxShallowRepositoryWatches` マーカー1件
- [x] `dpkg -l codex-desktop` → `2026.07.31.120326`
- [x] 旧プロセス3件の終了と自動再起動を確認
- [x] app-server の親が electron（孤児なし）
- [x] remote-control の ESTABLISHED 復活
- [x] Codex関連 inotify = 17
- [x] stock-monitor の timer・直近ジョブ・worktree に影響なしを確認
- [ ] **未検証**: `ai-news-collector` のタスクプレビューを実際に発生させた際の挙動
      （UI操作が必要。再発時は `launcher.log` に `ENOSPC` が出る）

## 残タスク

1. サイドバーで `ai-news-collector` をホバーし、`ENOSPC` が出ないこと・watch数が
   数十台に留まることを実測する
2. upstream追従でリビルドするたび、`applied=1` とasarマーカーを再確認する
   （バンドル形状が変わるとパッチが静かに外れる）

## 関連ファイル・リソース

- `CLAUDE.md` — 「有効化しているLinux機能」節
- `linux-features/shallow-repository-watches/README.md` — 機能の公式説明とトレードオフ
- `operations/2026-07-28-codex-desktop-upgrade-pkill-fix.md` — 前回作業（孤児app-serverの掃除）

---

**メタデータ**
- 作成日: 2026-07-31
- タグ: `#inotify` `#codex-desktop` `#linux-features` `#troubleshooting` `#ENOSPC`
