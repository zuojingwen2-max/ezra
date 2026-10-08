# AI 语音来电

AI 主动给你打电话:Telegram 推来电链接 → 手机点开接听 → 你说话(录音交给 ElevenLabs 转文字)→ Claude 以 Ezra 的身份回复 → ElevenLabs 念出来 → 挂断后存文字记录并可回放。

零依赖,只需要 Node 18+。

## 部署到腾讯云

```bash
git clone <本仓库> && cd ezra/voice-call
cp .env.example .env   # 填好各项
set -a; . ./.env; set +a; node server.js   # 先手动跑通
```

长期运行用 systemd(`EnvironmentFile=/path/.env`,`ExecStart=/usr/bin/node server.js`)或 pm2。

**必须 HTTPS**(手机只在 HTTPS 下给麦克风)。用 nginx 反代到 127.0.0.1:8787,并关闭 SSE 缓冲:

```nginx
location / {
  proxy_pass http://127.0.0.1:8787;
  proxy_http_version 1.1;
  proxy_buffering off;
  proxy_read_timeout 1h;
}
```

上海机房的域名需要 ICP 备案。

## 大陆服务器的网络问题

Telegram、ElevenLabs 从大陆服务器通常直连不通。三个地址都能改:`TELEGRAM_API_BASE`、`ELEVENLABS_BASE_URL`,以及你自己的 `LLM_WEBHOOK_URL`。
把它们指向一个能出海的中转(Cloudflare Worker、香港小机器上的 nginx 反代)即可。

## 接口

| 接口 | 说明 |
|---|---|
| `POST /api/ring` | 发起来电。`Authorization: Bearer $RING_TOKEN`,body `{"text":"来电说明"}`,返回通话链接 |
| `POST /api/push` | (可选)AI 在通话中主动插话,body `{id,text}`,同样需要 Bearer |
| `GET /api/calls` | 通话列表(需 Bearer) |
| `POST /api/answer` `/say` `/hangup` `GET /api/stream` `/tts` | 通话页内部使用,以通话 ID 作为凭证 |

发起来电:

```bash
curl -X POST https://call.example.com/api/ring -H "Authorization: Bearer $RING_TOKEN" -d '{"text":"想你了"}'
```

## 大脑

默认用 Claude API:把 Ezra 项目的指令复制进 `persona.md`,填 `ANTHROPIC_API_KEY` 即可。

## (可选)接你自己的聊天系统

设置了 `LLM_WEBHOOK_URL` 时,改为在每个事件上 POST 到 `LLM_WEBHOOK_URL`:

```json
{ "call_id": "...", "event": "answered | user | ended", "text": "用户这句话", "history": [{"role":"ai|user","text":"...","t":0}] }
```

返回 `{"reply":"要说的话"}`。`answered` 时返回开场白;`ended` 时返回值被忽略,用来通知聊天侧通话结束。

## 已知限制

- 语音识别:通话页本地检测音量切句,录音上传给 ElevenLabs Scribe 转文字,安卓和 iPhone 都能用。AI 说话时暂停收音,所以暂不支持打断。
- 目前存的是文字记录,没有录音回放。
- 记录按 `RETAIN_DAYS` 自动删除。
