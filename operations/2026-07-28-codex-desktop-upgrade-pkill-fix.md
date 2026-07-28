# Codex Desktop 定期アップグレード & pkill自己マッチの罠の修正

## 変更概要

- **日付**: 2026-07-28
- **作業者**: Claude Code (Opus 5 1M)
- **カテゴリ**: アップグレード / トラブルシューティング
- **影響範囲**: ローカル環境（Ubuntu 24.04）
- **ダウンタイム**: なし（アプリ再起動のみ、1秒で復帰）
- **リスクレベル**: 低

## 目的

前回作業（2026-07-12）から2週間分の upstream 変更に追従し、Desktop本体・Codex CLI・モデルカタログの3段構えを最新化する。

## 実施内容

### 1. upstream/main への追従（284コミット取り込み）

```bash
git fetch upstream
git merge upstream/main --no-edit
```

- `personal/notes` 上の独自コミットは個人メモ2件（`daf74b0`, `1fed072`）のみ、コンフリクトなし
- merge-base: `0fe4408` → upstream HEAD: `c6d7623`（SSH command-wrapper のハードニング等）

**注意**: CLAUDE.md に書かれていた `git pull --ff-only upstream main` は `personal/notes` では**使えない**。個人メモの独自コミットが載っているため fast-forward できない。手順を merge に訂正した（後述）。

### 2. ネイティブパッケージのビルド&インストール

```bash
make bootstrap-native
```

- 上流 `Codex.dmg` を再取得（キャッシュのメタデータが上流と差分あり → 自動リフレッシュ）
- 上流DMG受入判定: `accepted`
- `codex-update-manager` v0.10.3 (Rust) ビルド
- `.deb` ビルド: `codex-desktop_2026.07.28.003025_amd64.deb`
- sudoで上書きインストール（旧: `2026.07.12.084245`）
- 旧アプリのバックアップ: `codex-app.backup-20260728093016`

### 3. Codex CLI の更新

```bash
npm install -g --prefix=$HOME/.local @openai/codex@latest
```

- `0.144.1` → `0.145.0`

### 4. モデルキャッシュの再取得とプロセス入れ替え

```bash
rm ~/.codex/models_cache.json
pkill -f "/opt/codex-desktop/[e]lectron"
pkill -f "codex app-[s]erver"
```

- キャッシュは再起動時に自動再取得（285,588 → 304,145 bytes）
- app-server は electron 停止に伴い既に落ちていた（pkill は該当なしで終了）

### 5. 踏んだ罠: pkill が実行中のシェルを巻き添えにする

CLAUDE.md 記載の手順をそのまま実行したところ、**コマンドを実行しているシェル自身が落ちた**（exit 144）。

原因は `pkill -f` がプロセスの**コマンドライン全体**を検索する仕様。`pkill -f "codex app-server"` を実行すると、そのコマンドを起動した親シェルのコマンドラインにも `codex app-server` という文字列が含まれるため、親シェルがマッチして kill される。`pkill` は自分自身のプロセスは除外するが、親シェルは除外しない。

回避策は正規表現の文字クラスを使うこと。`[s]erver` は文字クラスとして `server` にマッチする一方、文字列としての `[s]erver` にはマッチしないため、自己マッチだけを消せる。

```bash
pkill -f "/opt/codex-desktop/[e]lectron"   # ブラケットが必須
pkill -f "codex app-[s]erver"
```

### 変更ファイル

| ファイル | 変更内容 |
|---------|---------|
| `CLAUDE.md` | pkill をブラケット表記に修正＋理由を追記、アップグレード手順を `git merge` に訂正、キャッシュ削除とkillが1セットである旨の相互参照を追加 |
| `operations/2026-07-28-*.md` | 本ファイル |

コミット: `64a5af3` → `origin/personal/notes` に push 済み

## 検証・テスト

- [x] `dpkg -l codex-desktop` → `2026.07.28.003025`
- [x] `codex --version` → `codex-cli 0.145.0`
- [x] models_cache.json の再生成を確認（304,145 bytes）
- [x] モデルID一覧に GPT-5.6系3種を確認: `gpt-5.6-luna` / `gpt-5.6-sol` / `gpt-5.6-terra`（他 `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark`）
- [x] kill 後にアプリが自動再起動することを確認（1秒で復帰）
- [x] 作業ツリーがクリーンで `origin/personal/notes` と同期していることを確認

## 関連ファイル・リソース

- `CLAUDE.md` — アップグレード手順と新モデルが出ないときのチェックリスト
- `operations/2026-07-12-codex-desktop-upgrade-gpt56.md` — 前回作業（GPT-5.6有効化）

---

**メタデータ**
- 作成日: 2026-07-28
- タグ: `#upgrade` `#codex-desktop` `#pkill` `#git-merge` `#troubleshooting`
