# Codex Desktop 更新の自動チェック（systemd user unit）

Codex Desktop が更新されたことを検知して、Linux独自機能（inotify対策のパッチ等）が
ちゃんと生き残っているかを自動で検証し、問題があればデスクトップ通知を出す。

## なぜ必要か

このforkは2つの「静かな失敗」経路を持つ。**ビルドが成功しても対策は外れ得る**。

1. `linux-features/features.json` は `.gitignore` 対象。gitに残らないので、
   cloneし直したりファイルを失うと有効化が消える
2. パッチは `ciPolicy: optional`。upstream更新でバンドル形状が変わってパターンが
   外れても、ビルドは成功扱いで進む（警告が出るだけ）

人間が毎回チェックを覚えている前提にしないため、更新イベントに機械を張り付ける。

## 仕組み

```
/opt/codex-desktop/resources/app.asar が変化
        ↓（systemd path unit が inotify で検知）
codex-features-check.service が起動
        ↓（30秒待ってからインストール完了後の状態を検証）
verify-linux-features.sh --notify
        ↓（問題があるときだけ）
デスクトップ通知
```

`app.asar` はアプリ本体そのもの。**手動リビルド（make）でもアプリ内更新でも必ず置き換わる**ので、
更新の経路を限定しなくても取りこぼさない。dpkg の rename 方式による置き換えでも
発火することは実測で確認済み（systemd はファイル監視時に親ディレクトリも見るため）。

## 設置

```bash
cp operations/systemd/codex-features-check.{path,service} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now codex-features-check.path
```

確認:

```bash
systemctl --user is-enabled codex-features-check.path   # enabled
systemctl --user is-active  codex-features-check.path   # active
```

## 通知の読み方

| 通知 | 意味 | 対処 |
|------|------|------|
| （何も出ない） | 正常 | なし |
| **独自機能が外れています**（赤） | パッチまたは設定が失われた | Claudeに「codex-desktopの検証して」と伝える。要リビルド |
| **再起動してください**（通常） | 更新は入ったが古いプロセスが動いている | Codex Desktop を再起動する |

## ログ

実行結果は毎回ここに追記される（通知を見逃しても後から確認できる）。

```bash
tail -30 ~/.cache/codex-desktop/feature-check.log
```

## 手動実行

更新とは関係なく今すぐ確認したいとき:

```bash
bash operations/verify-linux-features.sh
```

終了コード: `0`=正常 / `1`=設定かパッチに問題（要リビルド） / `2`=要再起動

## 一時的に止める / 外す

```bash
systemctl --user disable --now codex-features-check.path   # 止める
rm ~/.config/systemd/user/codex-features-check.{path,service} && systemctl --user daemon-reload  # 完全に外す
```

## 注意

- unit の実体は `~/.config/systemd/user/` にあり、**gitの管理外**。
  このディレクトリのファイルが正本なので、環境を作り直したら上記の設置手順を再実行する
- `Linger=yes` が有効なので、ログアウト中でも user unit は動く
- 監視に使う inotify は1ファイル分（枠1個）。対策している枯渇問題には影響しない
