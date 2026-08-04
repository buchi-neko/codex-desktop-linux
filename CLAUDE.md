# CLAUDE.md — codex-desktop-linux 作業メモ

このファイルはClaude Code用のプロジェクト固有メモ。公式のプロジェクトルールは `AGENTS.md` 参照。

## リポジトリ構成（重要）

このリポジトリは **公式ではなく他人のforkをclone** した状態から始まっている。remote構成:

| remote | URL | 用途 |
|--------|-----|------|
| `origin` | buchi-neko/codex-desktop-linux | **自分のfork（push先）** |
| `upstream` | ilysenko/codex-desktop-linux | 公式（pull元） |
| `robustonian` | robustonian/codex-desktop-linux | 元origin（参考用に保持） |

**運用ルール:**
- 個人メモ（CLAUDE.md / operations/）は `personal/notes` ブランチに置く
- `upstream-main` ブランチは公式追従専用（`git pull --ff-only upstream main`）
- 個人ブランチに公式変更を取り込む: `git checkout personal/notes && git merge upstream/main`
- **絶対に upstream や robustonian へは push しない**（権限もない）

## アップグレード手順（Ubuntu）

```bash
git fetch upstream && git merge upstream/main --no-edit
make bootstrap-native   # ビルド + .deb + sudoインストール
```

`personal/notes` には個人メモの独自コミットが載っているため `git pull --ff-only` は
**使えない**（fast-forwardできない）。merge を使うこと。

その後、新モデルを確実に拾うには下記2つまでやって1セット:
1. `rm ~/.codex/models_cache.json`（→「新モデルが出ないときのチェックリスト」3番）
2. 起動中プロセスのkill（→「起動プロセスの入れ替え」）

**ビルドが成功しても独自機能は静かに外れ得る**（設定がgitignore対象 + パッチがoptional）。
そのため検証は systemd で自動化してある。`app.asar` の変化を path unit が検知し、
**手動リビルドでもアプリ内更新でも**自動で検証してデスクトップ通知を出す:

| 通知 | 意味 | 対処 |
|------|------|------|
| （出ない） | 正常 | なし |
| 独自機能が外れています | パッチor設定が失われた | 要リビルド |
| 再起動してください | 更新は入ったが古いプロセスが動作中 | アプリ再起動 |

手動で確認する場合（設定・パッチ・プロセス・監視枠を1本で判定する）:

```bash
bash operations/verify-linux-features.sh   # 0=正常 / 1=要リビルド / 2=要再起動
```

自動チェックの設置・停止手順は `operations/systemd/README.md`。
ログは `~/.cache/codex-desktop/feature-check.log`。

## 新モデル（GPT-5.6等）が出ないときのチェックリスト

新モデル対応は **3段構え** で、どれか1つでも古いとUIに出ない：

1. **Desktopアプリ本体**（`/opt/codex-desktop/`）
   - `dpkg -l codex-desktop` で日付を確認、古ければ `make bootstrap-native`

2. **Codex CLI**（`~/.local/lib/node_modules/@openai/codex/`）
   - **これが最重要** — Desktopアプリが実行時に呼び出すCLI。npm製で独立更新。
   - `codex --version` で確認、古ければ:
     ```bash
     npm install -g --prefix=$HOME/.local @openai/codex@latest
     ```
   - OpenAIサーバーは `client_version` でモデルエンタイトルメントをゲートしている。CLIが古いと新モデルが models_cache に含まれない。

3. **モデルキャッシュ**（`~/.codex/models_cache.json`）
   - ETag付き長期キャッシュ。サーバー側にロールアウト済みでも即取りに行かない。
     ```bash
     rm ~/.codex/models_cache.json
     ```
   - アプリ再起動で自動再取得。

## 起動プロセスの入れ替え

`.deb`上書きインストールしても、既に起動中のElectron群は古いバイナリをメモリに保持したまま動き続ける。**手動killが必要**：

```bash
pkill -f "/opt/codex-desktop/[e]lectron"      # Desktop本体（start.sh経由で自動再起動する）
pkill -f "[a]pp-server --remote-control"      # ← 孤児化するので必ずセットで落とす
```

以下、2026-07-28に実際に踏んだ罠3つ。**どれか1つでも外すと古いプロセスが生き残る**。

### 罠1: `pkill -f` は実行中のシェル自身を巻き添えにする

`pkill -f` はプロセスのコマンドライン全体を検索するため、素直に
`pkill -f "codex app-server"` と書くと**このコマンドを実行しているシェル自身**
（コマンドラインにその文字列を含む）にもマッチして、シェルごと死ぬ。
ブラケットは正規表現の文字クラスなので `[a]pp-server` は `app-server` に
マッチする一方、文字列としての `[a]pp-server` にはマッチしない
→ 自己マッチだけを回避できる。**ブラケットは必須**。

### 罠2: `codex app-server` という連続文字列ではマッチしない

実際のコマンドラインは間に引数が挟まる:

```
node ~/.local/.../codex.js -c features.code_mode_host=true app-server --remote-control ...
                           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ここが挟まる
```

`codex` と `app-server` は隣接していないので、`pkill -f "codex app-[s]erver"` は
**空振りして exit 1（該当なし）を返す**。「該当なし＝もう落ちている」と誤読しやすい。
`app-server` 側だけでマッチさせること。

### 罠3: electron を kill しても app-server は道連れにならない（最重要）

electron を落としても app-server は終了せず、親を失って `systemd --user` に
再ペアレントされ**孤児として生き残る**。しかも孤児は chatgpt.com への
remote-control 接続を握ったままなので、新しい Desktop を起動しても
**7月13日時点の古いコードが通信し続けていた**（発見時点で15日間稼働）。

孤児の判別は**親PID**を見る。親が `systemd --user` なら孤児:

```bash
ps -eo pid,ppid,lstart,args | grep "[a]pp-server"
ps -p <PPID> -o comm=     # systemd と出たら孤児 → kill する
```

`ps` / `pgrep` ごと権限で弾かれることがある（2026-07-31に遭遇）。その場合は `/proc` を直接読む:

```bash
grep -al "app-server" /proc/[0-9]*/cmdline        # PIDを特定
tr '\0' ' ' < /proc/<pid>/cmdline                  # コマンドライン
awk '/^PPid:/{print $2}' /proc/<pid>/status        # 親PID
```

正常な app-server の親は必ず `/opt/codex-desktop/electron`。
kill は PID直指定が最も安全（自己マッチの心配がない）。親を落とせば子も終了する。

### 入れ替え後の検証

remote-control が復活したかは、app-server の実体（Rustバイナリの子プロセス）が
chatgpt.com へ ESTABLISHED 接続を張っているかで判定する。

```bash
ss -tnp | grep "pid=<app-serverのPID>"    # :443 へ ESTAB が出れば復活
```

`ss` も `ps` も使えない環境では `/proc/<pid>/fd` の socket inode を
`/proc/net/tcp6` と照合する（手順は `operations/2026-07-28-*.md` 参照）。

## 有効化しているLinux機能（linux-features/features.json）

このforkは公式にない機能を `linux-features/` に持ち、`features.json` で選んだものだけを
ビルド時にupstreamバンドルへパッチとして当てる。

**重要: `features.json` は `.gitignore` 対象**（`.gitignore:18`）。gitに残らないので、
cloneし直したりファイルを失うと**有効化が消え、次のリビルドで対策ごと巻き戻る**。

| 機能ID | 有効化 | 目的 |
|--------|--------|------|
| `remote-mobile-control` | 既存 | スマホからのリモート操作 |
| `shallow-repository-watches` | 2026-07-31 | inotify枯渇の防止（下記） |

### shallow-repository-watches（inotify枯渇対策）

サイドバーでタスクをホバーすると、Electronがそのリポジトリ全体へ再帰的な `fs.watch` を張る。
Linux版Nodeの再帰監視は**ファイル・ディレクトリ1個ごとにinotify枠を1個消費する**実装なので、
巨大リポジトリを一度覗いただけでユーザー上限（既定65,536）を使い切る。

2026-07-31の実測: `ai-news-collector`（111,557エントリ）のプレビューで Codex Desktop が
62,664 watch を確保し `ENOSPC` が614回発生。systemd user unit の監視まで巻き添えになった。

パッチはLinuxの再帰要求だけを非再帰へ落とす（実質3行）。代償は、深い階層の変更が即時反映されず
**ウィンドウのフォーカス復帰時に更新される**こと。日常操作ではほぼ気づかない。

競合機能 `directory-only-working-tree-watch` とは**同時に有効化できない**（どちらか一方）。

`ciPolicy: optional` のため **パッチが外れてもビルドは成功扱いで進む**（警告のみ）。
upstream更新でバンドル形状が変わるとパターンが外れる。検証は更新時に自動実行される
（→「アップグレード手順」）。手動で走らせるなら:

```bash
bash operations/verify-linux-features.sh
```

内訳を自分で確認する場合:

```bash
grep "feature shallow-repository-watches" <ビルドログ>   # applied=1 なら成功
grep -a -c "codexLinuxShallowRepositoryWatches" /opt/codex-desktop/resources/app.asar   # 1
```

効果の実測（上限は `/proc/sys/fs/inotify/max_user_watches`）:

```bash
{ for f in /proc/[0-9]*/cmdline; do pid=${f%/cmdline}; pid=${pid#/proc/}
  case "$(tr '\0' ' ' < "$f")" in */opt/codex-desktop/*|*@openai/codex*)
    grep -h '^inotify' /proc/$pid/fdinfo/* | wc -l;; esac
done; } 2>/dev/null | paste -sd+ | bc
```

対策後の正常値は数十以下（2026-07-31の実測で17）。数千〜数万なら効いていない。

## 設定・状態ファイルの場所

| パス | 内容 |
|------|------|
| `~/.codex/auth.json` | 認証トークン（logout で削除される） |
| `~/.codex/models_cache.json` | サーバー配信モデルカタログ |
| `~/.codex/config.toml` | ユーザー設定 |
| `~/.config/Codex/` | Electronのユーザーデータ（Cookie等） |
| `/opt/codex-desktop/` | アプリ本体 |
| `~/.local/lib/node_modules/@openai/codex/` | Codex CLI（Desktopが使用） |
| `linux-features/features.json` | 有効化するLinux独自機能（**gitignore対象＝gitに残らない**） |
| `/etc/sysctl.d/99-stock-monitor-inotify.conf` | inotify上限 262,144（stock-monitor側で設定。別管理） |

## 作業ログ

過去の作業内容は `operations/YYYY-MM-DD-*.md` に記録。
