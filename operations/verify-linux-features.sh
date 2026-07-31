#!/usr/bin/env bash
# Linux独自機能が「実際に」適用されているかを検証する。
#
# 使い方:  bash operations/verify-linux-features.sh
#
# なぜ必要か:
#   1. linux-features/features.json は .gitignore 対象。gitに残らないので
#      cloneし直すと有効化が消え、対策ごと巻き戻る。
#   2. パッチは ciPolicy:optional。upstream更新でバンドル形状が変わって
#      パターンが外れても、ビルドは成功扱いで進む（警告が出るだけ）。
#   つまり「ビルドが通った＝効いている」ではない。毎回これで確認する。

set -u

ASAR=/opt/codex-desktop/resources/app.asar
FEATURES="$(dirname "$0")/../linux-features/features.json"
ng=0

ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31m[NG]\033[0m   %s\n' "$1"; ng=1; }
info() { printf '         %s\n' "$1"; }

echo
echo "==== 1. 有効化設定 (linux-features/features.json) ===="
if [ ! -f "$FEATURES" ]; then
    fail "features.json がありません"
    info "gitignore対象なので clone直後は存在しません。手で作り直してください:"
    info '{ "enabled": ["remote-mobile-control", "shallow-repository-watches"] }'
else
    for feat in remote-mobile-control shallow-repository-watches; do
        if grep -q "\"$feat\"" "$FEATURES"; then
            ok "$feat が有効"
        else
            fail "$feat が features.json にありません（次のリビルドで機能が消えます）"
        fi
    done
fi

echo
echo "==== 2. パッチがインストール済みバンドルに入っているか ===="
if [ ! -f "$ASAR" ]; then
    fail "$ASAR がありません（Codex Desktop 未インストール？）"
else
    n=$(grep -a -c "codexLinuxShallowRepositoryWatches" "$ASAR" 2>/dev/null || echo 0)
    case "$n" in
        1) ok "shallow-repository-watches のマーカーを検出（1件）" ;;
        0) fail "マーカーが見つかりません＝パッチが当たっていません"
           info "features.json を確認して 'make install-native DMG=\$PWD/Codex.dmg' で再ビルド" ;;
        *) fail "マーカーが $n 件（想定は1件）。パッチが重複適用された可能性" ;;
    esac
fi

echo
echo "==== 3. 起動中プロセスが新バイナリか ===="
asar_t=$(stat -c %Y "$ASAR" 2>/dev/null || echo 0)
newest=0
# 走査中に消えるプロセスがあるので stderr は捨てる（{} はサブシェルではないので変数は残る）
{ for f in /proc/[0-9]*/cmdline; do
    pid=${f%/cmdline}; pid=${pid#/proc/}
    case "$(tr '\0' ' ' < "$f")" in
        "/opt/codex-desktop/electron --no-sandbox"*)
            t=$(stat -c %Y "/proc/$pid" || echo 0)
            [ "$t" -gt "$newest" ] && newest=$t ;;
    esac
done; } 2>/dev/null
if [ "$newest" -eq 0 ]; then
    info "Codex Desktop は起動していません（スキップ）"
elif [ "$asar_t" -eq 0 ]; then
    info "asar が読めないため新旧を判定できません（スキップ）"
elif [ "$newest" -ge "$asar_t" ]; then
    ok "起動中のアプリはインストール後に立ち上がっています"
else
    fail "古いプロセスが動いています（インストール前から起動したまま）"
    info "→ CLAUDE.md「起動プロセスの入れ替え」の手順で kill してください"
fi

echo
echo "==== 4. inotify 監視枠の消費 ===="
used=$({ for f in /proc/[0-9]*/cmdline; do pid=${f%/cmdline}; pid=${pid#/proc/}
    case "$(tr '\0' ' ' < "$f")" in */opt/codex-desktop/*|*@openai/codex*)
        grep -h '^inotify' /proc/$pid/fdinfo/* | wc -l;; esac
done; } 2>/dev/null | paste -sd+ | bc)
used=${used:-0}
limit=$(cat /proc/sys/fs/inotify/max_user_watches)
info "Codex関連: ${used} / 上限 ${limit}"
if [ "$used" -lt 1000 ]; then
    ok "正常（対策前は 62,664。数十〜数百なら効いています）"
else
    fail "多すぎます。再帰監視が復活している可能性があります"
    info "→ ~/.cache/codex-desktop/launcher.log の ENOSPC を確認"
fi

echo
if [ "$ng" -eq 0 ]; then
    printf '\033[32m==== すべて正常です ====\033[0m\n\n'
else
    printf '\033[31m==== 問題があります。上の [NG] を確認してください ====\033[0m\n\n'
fi
exit "$ng"
