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
# 第二处：链接也放进结构化结果（Claude Code / OpenClaw 只看这一部分）
old_sc = 'sc = {"id": e["id"], "name": "ezra", "text": spoken, "time": e["ts"][11:16]}'
new_sc = old_sc + '\n    sc["mp3"] = clip_url(e["id"])\n    sc["send_on_telegram"] = f"MEDIA:{sc[\'mp3\']}\\n[[audio_as_voice]]"'
if 'sc["mp3"]' not in s:
    if s.count(old_sc) != 1:
        sys.exit("✗ server.py 里没找到 voice_say 的返回结构，什么都没改")
    s = s.replace(old_sc, new_sc)
    open(p, "w", encoding="utf-8").write(s)
    print("✓ voice_say 的结构化结果里加上了 mp3 链接")
else:
    print("· 结构化结果已经有 mp3 链接，跳过")
# 第三处：voice_say(telegram=True) 由服务器自己把语音条发到她的 Telegram
if "telegram: bool = False" not in s:
    old_sig = 'speed: float = -1, ctx: Context = None):'
    old_doc = '    stability/style/speed: -1 = saved defaults (v4 ignores style and speed)."""'
    old_ret = '    return ToolResult(content=[TextContent(type="text", text=msg)], structured_content=sc)'
    old_hdr = '@mcp.tool(output_schema=None, meta={"ui": {"resourceUri": UI_URI}, "ui/resourceUri": UI_URI})\nasync def voice_say('
    for a in (old_sig, old_doc, old_ret, old_hdr):
        if s.count(a) != 1:
            sys.exit(f"✗ 没找到要改的地方（{a[:40]}…），第三处没改")
    helper = (
        'async def _tg_voice(url):\n'
        '    k = ccfg()\n'
        '    tok, chat = k.get("telegram_bot_token"), k.get("telegram_chat_id")\n'
        '    if not (tok and chat):\n'
        '        return "telegram: not configured"\n'
        '    base = k.get("telegram_api_base", "https://api.telegram.org").rstrip("/")\n'
        '    try:\n'
        '        async with httpx.AsyncClient(timeout=60, proxy=k.get("proxy") or None) as cl:\n'
        '            r = await cl.post(f"{base}/bot{tok}/sendVoice", json={"chat_id": chat, "voice": url})\n'
        '        return "telegram: sent" if r.status_code == 200 else f"telegram: {r.status_code} {r.text[:120]}"\n'
        '    except Exception as ex:\n'
        '        return f"telegram: failed ({type(ex).__name__})"\n\n\n')
    s = s.replace(old_hdr, helper + old_hdr)
    s = s.replace(old_sig, 'speed: float = -1, telegram: bool = False, ctx: Context = None):')
    s = s.replace(old_doc, '    `telegram`: True = also send this clip to her Telegram as a voice note (the server sends it;\n'
                           '    don\'t add MEDIA lines or [[tts:text]] then). Use it when you are not in the Claude app.\n' + old_doc)
    s = s.replace(old_ret, '    if telegram:\n'
                           '        sc["telegram"] = await _tg_voice(clip_url(e["id"]))\n'
                           '        sc.pop("send_on_telegram", None)\n'
                           '        msg += f"\\n{sc[\'telegram\']}"\n' + old_ret)
    open(p, "w", encoding="utf-8").write(s)
    print("✓ voice_say 加上了 telegram 参数（服务器直接发语音条）")
else:
    print("· telegram 参数已经有了，跳过")
if "MEDIA:{clip_url" in s:
    print("· 文字说明已经改过，跳过"); sys.exit(0)
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
