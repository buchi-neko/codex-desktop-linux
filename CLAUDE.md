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
git fetch upstream && git pull --ff-only upstream main
make bootstrap-native   # ビルド + .deb + sudoインストール
```

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
pkill -f "/opt/codex-desktop/electron"
pkill -f "codex app-server"
# start.sh 経由で新版が自動再起動する
```

## 設定・状態ファイルの場所

| パス | 内容 |
|------|------|
| `~/.codex/auth.json` | 認証トークン（logout で削除される） |
| `~/.codex/models_cache.json` | サーバー配信モデルカタログ |
| `~/.codex/config.toml` | ユーザー設定 |
| `~/.config/Codex/` | Electronのユーザーデータ（Cookie等） |
| `/opt/codex-desktop/` | アプリ本体 |
| `~/.local/lib/node_modules/@openai/codex/` | Codex CLI（Desktopが使用） |

## 作業ログ

過去の作業内容は `operations/YYYY-MM-DD-*.md` に記録。
