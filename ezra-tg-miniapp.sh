#!/usr/bin/env bash
# 把 Ezra 来电推送改成 Telegram 里的「📞 接听」按钮（Mini App，不跳浏览器）
# 用法：bash ezra-tg-miniapp.sh          只改来电按钮
#       bash ezra-tg-miniapp.sh --menu   另外在聊天框左下角加一个常驻按钮，打开语音页
#       bash ezra-tg-miniapp.sh --undo   恢复改之前的文件
set -e
APP=/root/ezra-voice
PY=$APP/app/server.py
HTML=$APP/app/call.html
BK=$APP/backup-tg-miniapp

if [ "$1" = "--undo" ]; then
  [ -d "$BK" ] || { echo "没有备份，什么都没改"; exit 1; }
  cp "$BK/server.py" "$PY"; cp "$BK/call.html" "$HTML"
  systemctl restart ezra-voice && echo "✓ 已恢复并重启 ezra-voice"
  exit 0
fi

[ -f "$PY" ] && [ -f "$HTML" ] || { echo "✗ 找不到 $PY 或 $HTML"; exit 1; }
if [ ! -d "$BK" ]; then mkdir -p "$BK"; cp "$PY" "$HTML" "$BK/"; echo "✓ 已备份到 $BK"; fi

python3 - "$PY" "$HTML" <<'PY_EOF'
import sys, re
py, html = sys.argv[1], sys.argv[2]

s = open(py, encoding="utf-8").read()
if "web_app" in s:
    print("· server.py 已经改过，跳过")
else:
    old_def = 'async def _push_telegram(text):'
    new_def = 'async def _push_telegram(text, link=None):'
    old_post = 'json={"chat_id": chat, "text": text})'
    new_post = ('json={"chat_id": chat, "text": text, **({"reply_markup": {"inline_keyboard": ['
                '[{"text": "📞 接听", "web_app": {"url": link}}], '
                '[{"text": "在浏览器里打开", "url": link}]]}} if link else {})})')
    old_call = '_push_telegram(f"📞 {title}\\n{link}")'
    new_call = '_push_telegram(f"📞 {title}", link)'
    for a in (old_def, old_post, old_call):
        if s.count(a) != 1:
            sys.exit(f"✗ server.py 里没找到要改的那一行（{a[:40]}…），版本可能不是 v29，什么都没改")
    s = s.replace(old_def, new_def).replace(old_post, new_post).replace(old_call, new_call)
    open(py, "w", encoding="utf-8").write(s)
    print("✓ server.py：来电推送改成按钮")

h = open(html, encoding="utf-8").read()
if "telegram-web-app.js" in h:
    print("· call.html 已经改过，跳过")
else:
    inject = """<script src="https://telegram.org/js/telegram-web-app.js" async></script>
<script>
addEventListener('load', () => {
  const w = window.Telegram && Telegram.WebApp;
  if (!w || !w.initData) return;            // 普通浏览器里打开就什么都不做
  w.ready(); w.expand();
  try { w.disableVerticalSwipes(); } catch (e) {}   // 下滑不会误关
  try { w.enableClosingConfirmation(); } catch (e) {} // 关之前问一句
});
</script>
</head>"""
    if h.count("</head>") != 1:
        sys.exit("✗ call.html 结构跟预期不一样，什么都没改")
    open(html, "w", encoding="utf-8").write(h.replace("</head>", inject))
    print("✓ call.html：在 Telegram 里打开时全屏、防误关")
PY_EOF

$APP/venv/bin/python -m py_compile "$PY" && echo "✓ server.py 语法检查通过"
systemctl restart ezra-voice
sleep 2
systemctl is-active --quiet ezra-voice && echo "✓ ezra-voice 已重启" || { echo "✗ 重启失败，看日志：journalctl -u ezra-voice -n 30"; exit 1; }

if [ "$1" = "--menu" ]; then
  J=$APP/.call.json
  TOK=$(python3 -c "import json;print(json.load(open('$J')).get('telegram_bot_token') or '')")
  CHAT=$(python3 -c "import json;print(json.load(open('$J')).get('telegram_chat_id') or '')")
  BASE=$(python3 -c "import json;print((json.load(open('$J')).get('telegram_api_base') or 'https://api.telegram.org').rstrip('/'))")
  PROXY=$(python3 -c "import json;print(json.load(open('$J')).get('proxy') or '')")
  PUB=$(systemctl show ezra-voice -p Environment | grep -o 'EZRA_VOICE_PUBLIC=[^ ]*' | cut -d= -f2)
  PUB=${PUB:-https://voice.quietfire.cloud}
  WT=$(cat $APP/.web_token)
  [ -n "$TOK" ] && [ -n "$CHAT" ] || { echo "✗ .call.json 里没有 telegram_bot_token / telegram_chat_id，菜单按钮没设"; exit 1; }
  BODY=$(python3 -c "import json,sys;print(json.dumps({'chat_id':sys.argv[1],'menu_button':{'type':'web_app','text':'Ezra','web_app':{'url':sys.argv[2]+'/?t='+sys.argv[3]}}}))" "$CHAT" "$PUB" "$WT")
  R=$(curl -s ${PROXY:+-x "$PROXY"} -H 'Content-Type: application/json' -d "$BODY" "$BASE/bot$TOK/setChatMenuButton")
  echo "$R" | grep -q '"ok":true' && echo "✓ 聊天框左下角加了「Ezra」按钮（打开语音页）" || echo "✗ 菜单按钮没设上：$R"
fi

echo
echo "完成。在 Claude 那边让 Ezra 打一通电话（call_her），Telegram 里会出现「📞 接听」按钮。"
