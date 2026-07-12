# Codex Desktop Linuxアップグレード & GPT-5.6有効化

## 変更概要

- **日付**: 2026-07-12
- **作業者**: Claude Code (Sonnet 4.6 → Opus 4.7 1M)
- **カテゴリ**: アップグレード / トラブルシューティング
- **影響範囲**: ローカル環境（Ubuntu 24.04）
- **ダウンタイム**: なし（アプリ再起動のみ）
- **リスクレベル**: 低

## 目的

2026-07-09のOpenAI発表（Codex×ChatGPT統合、GPT-5.6ロールアウト）に追従。Ubuntu環境で最新版Codex Desktopを使い、モデル選択でGPT-5.6（Sol/Terra/Luna）を選べるようにする。

## 実施内容

### 1. upstream/mainへの追従（468コミット取り込み）

```bash
git fetch upstream
git pull --ff-only upstream main
```

- `upstream-main` ブランチは fast-forward 可能だったためコンフリクトなし
- HEAD: `0006f4a` → `0fe4408` (Codex 26.707.51957対応)

### 2. ネイティブパッケージのビルド&インストール

```bash
make bootstrap-native
```

- 上流 `Codex.dmg` (535MB) をDL → 抽出 → Linux互換パッチ適用
- `codex-update-manager` (Rust) ビルド
- `.deb` ビルド: `codex-desktop_2026.07.12.084245_amd64.deb`
- sudoで上書きインストール（旧: `2026.06.24.012312`）
- 内部バージョン: v0.9.5
- 警告1件: `linux-settings-search-visibility` パッチが挿入ポイント未検出でスキップ（無害）

### 3. 古いプロセスの入れ替え

- 7/4起動の旧版Electronプロセス群がずっと動いており、新版が読み込まれていなかった
- 旧プロセス全kill → `start.sh` 経由で新版が自動再起動

### 4. GPT-5.6が出ない問題の解決

**症状**: モデル選択にGPT-5.5までしか表示されず、Sol/Terra/Lunaが出ない

**原因**: `.local/bin/codex` (Desktopアプリが使用するCLI) が **0.142.5** で古かった。OpenAIサーバー側は `client_version` でエンタイトルメントをゲートしており、0.142.5だとGPT-5.6を返さない。

**対処**:
```bash
npm install -g --prefix=$HOME/.local @openai/codex@latest  # → 0.144.1
rm ~/.codex/models_cache.json
# アプリ再起動 → キャッシュ再取得
```

**結果**: models_cache に `gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna` が出現、UIでも選択可能に。

### 変更ファイル

| パス | 変更内容 |
|------|---------|
| `/opt/codex-desktop/` | v2026.06.24 → v2026.07.12 (dpkg経由) |
| `~/.local/lib/node_modules/@openai/codex/` | 0.142.5 → 0.144.1 |
| `~/.codex/models_cache.json` | 再生成（GPT-5.6含む） |
| `~/.codex/auth.json` | ログアウト→再ログインで再生成 |
| このgitリポジトリ | `upstream-main` を upstream/main へ fast-forward |

## 検証・テスト

- [x] `dpkg -l codex-desktop` で `2026.07.12.084245` を確認
- [x] `codex --version` で `0.144.1` を確認
- [x] `models_cache.json` に `gpt-5.6-sol/terra/luna` が含まれることをJSON確認
- [x] Desktop UIのモデル選択でGPT-5.6が表示されることをユーザーが確認

## 関連ファイル・リソース

- Upstream: https://github.com/ilysenko/codex-desktop-linux
- OpenAI Codex changelog: https://developers.openai.com/codex/changelog
- 旧アプリバックアップ: `codex-app.backup-20260712174236/`
- `.deb`: `dist/codex-desktop_2026.07.12.084245_amd64.deb`

## 学び・ハマりポイント

1. **Desktop `.deb` 更新だけでは不十分** — `.local` 配下のnpm製Codex CLIも独立して更新が必要。GPT-5.6などの新モデル可視化は **CLIバージョンでゲート** されている。
2. **旧プロセスは自動で入れ替わらない** — dpkg上書き後も、既に起動していたElectron群は古いバイナリを保持したまま動き続ける。手動killで新版に切り替え。
3. **models_cacheはETag付きで長期キャッシュ** — サーバー側にロールアウト済みでもクライアントが取りに行かない。cache削除で即反映。

---

**メタデータ**
- 作成日: 2026-07-12
- タグ: `#codex-desktop` `#ubuntu` `#gpt-5.6` `#openai` `#upgrade`
