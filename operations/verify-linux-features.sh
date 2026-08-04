#!/usr/bin/env bash
# Linux独自機能が「実際に」適用されているかを検証する。
#
# 使い方:
#   bash operations/verify-linux-features.sh            画面に結果を表示する
#   bash operations/verify-linux-features.sh --notify   問題があればデスクトップ通知（自動実行用）
#
# 終了コード:
#   0 = すべて正常
#   1 = 設定やパッチに問題がある（リビルドが必要）
#   2 = パッチは正常。ただし古いプロセスが動いている（再起動が必要）
#
# なぜ必要か:
#   1. linux-features/features.json は .gitignore 対象。gitに残らないので
#      cloneし直すと有効化が消え、対策ごと巻き戻る。
#   2. パッチは ciPolicy:optional。upstream更新でバンドル形状が変わって
#      パターンが外れても、ビルドは成功扱いで進む（警告が出るだけ）。
#   つまり「ビルドが通った＝効いている」ではない。更新のたびにこれで確認する。
#
# 自動実行:
#   systemd の path unit が app.asar の変化（＝更新）を検知して --notify 付きで呼ぶ。
#   設置手順は operations/systemd/README.md を参照。

set -u

ASAR=/opt/codex-desktop/resources/app.asar
FEATURES="$(cd "$(dirname "$0")/.." && pwd)/linux-features/features.json"
LOGFILE="${XDG_CACHE_HOME:-$HOME/.cache}/codex-desktop/feature-check.log"

NOTIFY=0
[ "${1:-}" = "--notify" ] && NOTIFY=1

ng_patch=0      # 設定・パッチの異常（深刻）
ng_process=0    # 古いプロセスが動いている（再起動で解決）

if [ "$NOTIFY" = 1 ]; then
    # 自動実行時は色を付けない（ログに制御文字が混ざるため）
    ok()   { printf '  [OK]   %s\n' "$1"; }
    fail() { printf '  [NG]   %s\n' "$1"; }
    info() { printf '         %s\n' "$1"; }
else
    ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
    fail() { printf '  \033[31m[NG]\033[0m   %s\n' "$1"; }
    info() { printf '         %s\n' "$1"; }
fi

run_checks() {
    echo
    echo "==== 1. 有効化設定 (linux-features/features.json) ===="
    if [ ! -f "$FEATURES" ]; then
        fail "features.json がありません"; ng_patch=1
        info "gitignore対象なので clone直後は存在しません。作り直してください:"
        info '{ "enabled": ["remote-mobile-control", "shallow-repository-watches"] }'
    else
        for feat in remote-mobile-control shallow-repository-watches; do
            if grep -q "\"$feat\"" "$FEATURES"; then
                ok "$feat が有効"
            else
                fail "$feat が features.json にありません（次のリビルドで機能が消えます）"
                ng_patch=1
            fi
        done
    fi

    echo
    echo "==== 2. パッチがインストール済みバンドルに入っているか ===="
    if [ ! -f "$ASAR" ]; then
        fail "$ASAR がありません（Codex Desktop 未インストール？）"; ng_patch=1
    else
        n=$(grep -a -c "codexLinuxShallowRepositoryWatches" "$ASAR" 2>/dev/null || echo 0)
        case "$n" in
            1) ok "shallow-repository-watches のマーカーを検出（1件）" ;;
            0) fail "マーカーが見つかりません＝パッチが当たっていません"; ng_patch=1
               info "features.json を確認して 'make install-native DMG=\$PWD/Codex.dmg' で再ビルド" ;;
            *) fail "マーカーが $n 件（想定は1件）。パッチが重複適用された可能性"; ng_patch=1 ;;
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
        ng_process=1
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
        fail "多すぎます。再帰監視が復活している可能性があります"; ng_patch=1
        info "→ ~/.cache/codex-desktop/launcher.log の ENOSPC を確認"
    fi
    echo
}

if [ "$NOTIFY" = 1 ]; then
    mkdir -p "$(dirname "$LOGFILE")"
    # コマンド置換 "$(run_checks)" はサブシェルを作り ng_* の結果が親へ返らない
    # （＝異常を検知できない）。リダイレクトなら同じシェルで走るのでこの形を使うこと。
    tmp="$(mktemp)"
    run_checks > "$tmp" 2>&1
    { printf '===== %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')"; cat "$tmp"; } >> "$LOGFILE"
    rm -f "$tmp"
else
    run_checks
fi

# ---- 判定と通知 ----
if [ "$ng_patch" -ne 0 ]; then
    rc=1
elif [ "$ng_process" -ne 0 ]; then
    rc=2
else
    rc=0
fi

if [ "$NOTIFY" = 1 ]; then
    case "$rc" in
        1) notify-send -u critical -i dialog-error \
             "Codex Desktop: 独自機能が外れています" \
             "更新でinotify対策のパッチが外れました。Claudeに「codex-desktopの検証して」と伝えてください。詳細: $LOGFILE" \
             2>/dev/null ;;
        2) notify-send -u normal -i dialog-information \
             "Codex Desktop: 再起動してください" \
             "更新は適用されましたが、まだ古いプロセスが動いています。アプリを再起動すると新しい版に切り替わります。" \
             2>/dev/null ;;
    esac
else
    case "$rc" in
        0) printf '\033[32m==== すべて正常です ====\033[0m\n\n' ;;
        1) printf '\033[31m==== 問題があります。上の [NG] を確認してください ====\033[0m\n\n' ;;
        2) printf '\033[33m==== パッチは正常。アプリの再起動が必要です ====\033[0m\n\n' ;;
    esac
fi

exit "$rc"
