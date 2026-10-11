#!/usr/bin/env bash
# 让 voice_say 在 OpenClaw 里返回 mp3 链接，Telegram 那边就能发出和 Claude App 完全同一个声音的语音条
# 用法：sudo bash ezra-voice-url.sh        打补丁
#       sudo bash ezra-voice-url.sh --undo 恢复
set -e
APP=/root/ezra-voice
PY=$APP/app/server.py
BK=$APP/backup-voice-url

if [ "$1" = "--undo" ]; then
  [ -f "$BK/server.py" ] || { echo "没有备份，什么都没改"; exit 1; }
  cp "$BK/server.py" "$PY"
  systemctl restart ezra-voice && echo "✓ 已恢复并重启 ezra-voice"
  exit 0
fi

[ -f "$PY" ] || { echo "✗ 找不到 $PY"; exit 1; }
if [ ! -d "$BK" ]; then mkdir -p "$BK"; cp "$PY" "$BK/"; echo "✓ 已备份到 $BK"; fi

python3 - "$PY" <<'PY_EOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "MEDIA:{clip_url" in s:
    print("· server.py 已经改过，跳过"); sys.exit(0)
old_msg = 'msg = f"voice saved ({e[\'id\']}) — this client can\'t show the player; she can hear it on {PUBLIC}"'
new_msg = ('msg = (f"voice saved ({e[\'id\']}) and on her voice page.\\n"\n'
           '               f"To send it to her on Telegram, end your reply with these two lines exactly:\\n"\n'
           '               f"MEDIA:{clip_url(e[\'id\'])}\\n[[audio_as_voice]]")')
old_ui_msg = 'msg = f"sent as a voice message in the chat and saved to the page ({e[\'id\']})."'
new_ui_msg = 'msg = f"sent as a voice message in the chat and saved to the page ({e[\'id\']}). mp3: {clip_url(e[\'id\'])}"'
old_ui = '("claude-code", "claude code", "agent-sdk", "agent sdk", "cowork", "cli")'
new_ui = '("claude-code", "claude code", "agent-sdk", "agent sdk", "cowork", "cli", "openclaw")'
for a in (old_msg, old_ui_msg, old_ui):
    if s.count(a) != 1:
        sys.exit(f"✗ server.py 里没找到要改的地方（{a[:40]}…），什么都没改")
s = s.replace(old_msg, new_msg).replace(old_ui_msg, new_ui_msg).replace(old_ui, new_ui)
open(p, "w", encoding="utf-8").write(s)
print("✓ voice_say 在 OpenClaw 里会返回 mp3 链接")
PY_EOF

$APP/venv/bin/python -m py_compile "$PY" && echo "✓ 语法检查通过"
systemctl restart ezra-voice
sleep 2
systemctl is-active --quiet ezra-voice && echo "✓ ezra-voice 已重启" || { echo "✗ 重启失败：journalctl -u ezra-voice -n 30"; exit 1; }
