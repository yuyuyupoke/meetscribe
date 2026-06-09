#!/usr/bin/env bash
# Clawd Listen v2 の E2E テスト (ウィンドウ座標を動的取得)
set -uo pipefail

APP_BIN="$(cd "$(dirname "$0")/.." && pwd)/dist/Clawd Listen.app/Contents/MacOS/ClawdListen"
LOG="/tmp/clawd-e2e.log"
RESULT="/tmp/clawd-e2e-result.txt"

rm -f "$LOG" "$RESULT"

kill_app() { pkill -f "ClawdListen" 2>/dev/null; sleep 0.5; }

launch_app() {
    kill_app
    nohup "$APP_BIN" > "$LOG" 2>&1 &
    disown
    sleep 2.5
    pgrep -f ClawdListen > /dev/null
}

# ウィンドウ絶対座標を取得して変数にセット
get_window_bounds() {
    osascript <<EOF
tell application "System Events"
    tell process "ClawdListen"
        set frontmost to true
        delay 0.3
        try
            set wPos to position of window 1
            set wSize to size of window 1
            set x1 to item 1 of wPos
            set y1 to item 2 of wPos
            set w to item 1 of wSize
            set h to item 2 of wSize
            return (x1 as text) & "," & (y1 as text) & "," & (w as text) & "," & (h as text)
        on error
            return "0,0,0,0"
        end try
    end tell
end tell
EOF
}

run_case() {
    local NAME="$1"
    local SCRIPT="$2"
    echo "== $NAME =="
    if ! pgrep -f ClawdListen > /dev/null; then
        launch_app || { echo "  ❌ couldn't launch"; echo "$NAME: FAIL_LAUNCH" >> "$RESULT"; return; }
    fi
    osascript <<EOF 2>/dev/null
tell application "System Events"
    tell process "ClawdListen"
        set frontmost to true
    end tell
    delay 0.3
    $SCRIPT
end tell
EOF
    sleep 0.8
    if pgrep -f ClawdListen > /dev/null; then
        echo "  ✅ PASS"
        echo "$NAME: PASS" >> "$RESULT"
    else
        echo "  ❌ CRASHED"
        echo "$NAME: CRASHED" >> "$RESULT"
    fi
}

echo "=== E2E Tests Start ==="
launch_app || { echo "Initial launch failed"; exit 1; }
echo "✅ Initial launch"
sleep 1

BOUNDS=$(get_window_bounds)
IFS=',' read -r WX WY WW WH <<< "$BOUNDS"
echo "Window bounds: x=$WX y=$WY w=$WW h=$WH"

# テキストフィールドの絶対座標 (右カラム下部)
TEXT_X=$((WX + (WW * 3 / 4)))
TEXT_Y=$((WY + WH - 40))
echo "TextField approx: ($TEXT_X, $TEXT_Y)"

# モデルボタンの絶対座標 (右カラム上部)
MODEL_Y=$((WY + 180))

# 1. アイドル
run_case "01_idle" '
    delay 1
'

# 2. テキストフィールドクリック
run_case "02_click_text_field" "
    click at {$TEXT_X, $TEXT_Y}
    delay 0.5
"

# 3. クリック後1文字入力
run_case "03_type_single_char" "
    click at {$TEXT_X, $TEXT_Y}
    delay 0.5
    keystroke \"a\"
    delay 0.5
"

# 4. 日本語もどきの文字入力 (ASCIIだが)
run_case "04_type_word" "
    click at {$TEXT_X, $TEXT_Y}
    delay 0.5
    keystroke \"hello\"
    delay 0.5
"

# 5. Return 送信
run_case "05_enter_submit" "
    click at {$TEXT_X, $TEXT_Y}
    delay 0.3
    keystroke \"x\"
    delay 0.3
    keystroke return
    delay 0.5
"

# 6. 全選択 + 削除
run_case "06_select_all_delete" "
    click at {$TEXT_X, $TEXT_Y}
    delay 0.3
    keystroke \"abc\"
    delay 0.2
    keystroke \"a\" using command down
    delay 0.2
    key code 51
    delay 0.3
"

# 7. モデルボタン連打 (Opus, Sonnet, Haiku 辺り)
run_case "07_model_buttons" "
    click at {$((WX + (WW/2) + 120)), $MODEL_Y}
    delay 0.3
    click at {$((WX + (WW/2) + 180)), $MODEL_Y}
    delay 0.3
    click at {$((WX + (WW/2) + 240)), $MODEL_Y}
    delay 0.3
"

# 8. ウィンドウのタイトルバー辺りをクリック (無害)
run_case "08_title_bar_click" "
    click at {$((WX + WW/2)), $((WY + 15))}
    delay 0.3
"

# 9. 空 Enter (空欄 submit)
run_case "09_empty_enter" "
    click at {$TEXT_X, $TEXT_Y}
    delay 0.3
    keystroke return
    delay 0.5
"

# 10. 連続操作
run_case "10_combo" "
    click at {$TEXT_X, $TEXT_Y}
    delay 0.2
    keystroke \"one\"
    delay 0.1
    keystroke \"a\" using command down
    key code 51
    delay 0.1
    keystroke \"two\"
    delay 0.2
    keystroke return
    delay 0.3
"

kill_app
echo ""
echo "=== E2E Results ==="
cat "$RESULT"
echo ""
PASS=$(grep -c "PASS" "$RESULT" || echo 0)
FAIL=$(grep -c "CRASHED\|FAIL" "$RESULT" || echo 0)
echo "PASS: $PASS / FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "=== app log tail ==="
    tail -30 "$LOG"
    exit 1
fi
exit 0
