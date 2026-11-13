# Loft Mobile: build plan

Status: design done, no code yet. Android first, iOS later.

Loft Mobile lets you prompt and control your Claude Code background agents on your
computer from your phone, across all your accounts. It is a phone front end for the existing Loft server
(`server.py` in the Loft repo). It mirrors desktop Loft v2's flows and is built for voice.

  It uses the file's own variables (color/space/radius), Geist + Geist Mono, the
  Agent item, Button and Usage meter components, and the Loft mark. The page adds
  one component, **Voice dock**, with the states Idle / Listening / Transcribing /
  Ready / Phone speech.
- Screens, at 412x915 (dark): 1 Pair, 2 Inbox, 3 It's asking, 4 It's asking ·
  Listening, 5 New task, 6 New task · Listening, 7 Terminal, 8 Inbox · Offline.

---

## 1. Transport and security

Loft can start shells and agents under both logins, so a stolen token gives
remote code execution on the laptop. The rules:

- **Never bind 0.0.0.0.** Loft keeps `127.0.0.1:7717` and can *also* listen on
  the laptop's Tailscale IPv4 only (`tailscale ip -4` = 100.x.y.z), port 7717.
- **Off by default.** Desktop Loft gets a "Phone access" switch. The setting is
  stored in `~/.config/loft/config.json`, and the tailnet listener runs only while
  it is on.
- **Per-device pairing tokens.** Each one is long-lived and revocable, and only its
  sha256 hash is stored, in `~/.config/loft/devices.json` (mode 0600, directory
  0700). The desktop per-run token stays as it is for the browser UI.
- **Tailscale already encrypts the link** with WireGuard, so plain HTTP inside the
  tailnet is fine. `tailscale serve` was rejected: it proxies through 127.0.0.1,
  which would expose the localhost-only pairing endpoints to the tailnet.

### Exact `server.py` changes (M0)

1. **Config + device store.** Add `CONF_DIR = ~/.config/loft` (0700) and two helpers,
   `load_devices()` and `save_devices()`, that write atomically with
   `os.open(..., 0o600)`. A record looks like:
   `{id, name, sha256, created, last_seen, last_ip}`.
2. **Second listener.** In `main()`, if phone access is on, start a second
   `ThreadingHTTPServer((TS_IP, PORT), RemoteH)` in a thread. `TS_IP` comes from
   `tailscale ip -4`. Refuse to start unless that IP is in `100.64.0.0/10`. Also
   allow `--tailnet` / `--no-tailnet` flags, and re-check the IP when the switch
   is toggled.
3. **`RemoteH(H)` subclass for the tailnet listener:**
   - Reject any peer outside `100.64.0.0/10` (`self.client_address[0]`).
     Optionally, allowlist the peer's node through
     `tailscale whois --json <ip>` (user = you, node = your phone).
   - `_authed()` accepts **only** `Authorization: Bearer <device token>`, compared
     against the stored hashes with `secrets.compare_digest`. No `?t=` query token
     on this listener: Dart's `WebSocket.connect` and our own SSE client can both
     send headers, and a query token ends up in logs. On success, update
     `last_seen` / `last_ip`.
   - Do not serve `/`, `/index.html` or `/static/` (they bake in the desktop
     token). Return 404.
   - Rate-limit failed auth: after 5 failures a minute from one IP, return 429 for
     10 minutes.
   - Block localhost-only routes: `/api/pair*` and `/api/devices*`.
4. **Pairing routes on the localhost listener only**, behind the desktop token:
   - `POST /api/pair {name}` mints `secrets.token_urlsafe(32)`, stores its hash,
     and returns `{id, uri}` where `uri = loft://pair?h=100.x.y.z:7717&t=<token>&n=laptop`.
     The token is shown once.
   - `GET /api/devices` lists devices (no secrets). `DELETE /api/devices/<id>` revokes one.
   - Revoking also closes that device's open SSE and WebSocket connections. Track
     open handlers per device id and flag them, so `events()` and `term_ws()` exit
     on their next loop.
5. **Device tokens on localhost too.** Accept them on the loopback listener as
   well, so the Android emulator can reach the host through `10.0.2.2:7717` during
   development.
6. **`/api/voice` accepts phone audio.** Map `audio/mp4`, `audio/aac` and
   `audio/m4a` to `.m4a` (ffmpeg probes the content anyway). Keep the 25 MB cap.
   Return `{text, ms}`.
7. **`GET /api/ping`** (authed) returns `{host:"fedora", version, voice:bool}`. Use
   it for the Connect check and the offline retry.
8. **Desktop UI (`index.html`).** Add the "Phone access" switch, a "Pair phone"
   dialog that shows the QR, and the device list with Revoke. Render the QR with a
   small vendored QR library in `static/` (no CDN).
9. **Unchanged:** account handling. Every action still goes through
   `B.account_env(card["work"])`, which sets `CLAUDE_SECURESTORAGE_CONFIG_DIR`
   explicitly for work and for personal. The phone only sends `account:"work"|"personal"`.

### API the app uses (existing, as implemented)

| Need | Route |
|---|---|
| Live state | `GET /api/events` (SSE, the full snapshot, sent when it changes, ping every 2 s) |
| One-shot state | `GET /api/state` |
| History | `GET /api/timeline/<id>` |
| Create (Start / Save to Todo) | `POST /api/cards` `{prompt, title?, account, cwd, start}` |
| Card actions | `POST /api/cards/<id>/<action>`: `reply {text}`, `start {prompt?}`, `stop`, `archive`, `pin`, `rename`, `account`, `prompt` |
| Terminal | WebSocket `/ws/term/<id>`: binary is pty bytes, text JSON is `{type:"resize",rows,cols}` or `{type:"input",data}` |
| Voice | `POST /api/voice` (body = audio) returns `{text}` |
| Folder picker | `GET /api/fs?path=<~/x>[&hidden=1]` returns `{path, display, parent, dirs: [{name, path, display, git, web}], recent: [same items], truncated}`; 403 outside home; 404 on `~` = older Loft (Browse hidden, typed entry stays) |
| Browsers | `GET /api/sites` (accounts with sites + agents with a browser); WebSocket `/ws/browser/<id>` and `/ws/sites/<account>`: binary = JPEG frames, text = JSON events and input (Loft docs/browser-protocol.md). A refused upgrade (404/403) shows "not shared" |

(The brief called the action route `/api/act`. In `server.py` it is
`/api/cards/...`, as listed above.)

## 2. Voice

- **Default: the laptop's Whisper.** Record AAC-LC m4a (16 kHz mono) with
  `record` and POST it to `/api/voice`. It uses the same faster-whisper small.en
  model and the same vocabulary hint (n8n, Zoho, ...) as desktop, so quality is
  the same. Expect about 1 s per clip once the model is warm.
- **Fallback: Android on-device speech** (`speech_to_text`). It is used when
  `/api/ping` fails or the upload times out (8 s). The dock shows the
  "Phone speech · fedora unreachable" state, and sends wait in an outbox until
  fedora is back. Brand names may be wrong in this mode, so the text stays
  editable.
- **Live words while listening.** The designs show partial text during recording.
  Android usually won't let `SpeechRecognizer` and `AudioRecord` use the mic at the
  same time, so test this on a real phone first. If both can run, use phone speech
  for the live preview and Whisper for the final text. If not, there are two
  options: (a) show only the level meter and timer, with text appearing about 1 s
  after release, or (b) add `/ws/voice` on the laptop, which takes ~2 s chunks and
  returns partials. **v1 = (a).**
- **Gestures.** Hold the mic to talk, release to transcribe, slide left to cancel.
  Tap to keep listening, tap again to stop. Haptic tick on start and stop.
- **Hands-free submit (same as desktop).** After the final transcript, apply
  desktop's regex `/[,.]?\s*(start it|send it|go ahead and send( it)?)[.!]?$/i`.
  On the reply composer, "send it" sends. On New task, "start it" starts. Strip
  the phrase from the text and show a 2 s Undo toast before the action fires.
- **Terminal mic.** It pastes the transcript at the prompt with bracketed paste
  (`\e[200~...\e[201~`) and does not press Enter. Enter is its own key.

## 3. Flutter app

### Stack

| Concern | Choice |
|---|---|
| State | `flutter_riverpod` (one `snapshotProvider` from SSE, `connectionProvider`, `voiceController`) |
| Routing | `go_router` (stack: Inbox → Agent → Terminal, New task as a full-screen sheet; system back works) |
| HTTP + SSE | `http` with a small hand-written SSE parser (needs the `Authorization` header, which most SSE packages don't send) |
| WebSocket | `web_socket_channel` (`IOWebSocketChannel.connect(uri, headers:{Authorization})`) |
| Terminal | `xterm` (xterm.dart): resize sent from the measured cols/rows, ~52 cols at 12 px on 412 dp |
| Recording | `record` (AAC m4a, amplitude stream for the level bars) |
| Phone speech | `speech_to_text` |
| QR | `mobile_scanner` (parses `loft://pair?...`) |
| Secrets | `flutter_secure_storage` (host, device token, device id; Android Keystore) |
| Notifications | `flutter_local_notifications` + `flutter_foreground_task` (see open decisions) |
| Fonts | Geist and Geist Mono bundled as assets |
| Theme | `lib/theme/tokens.dart` generated by hand from the Figma variables (gray/950...100, blue/500 work, green/500 personal, amber/500 needs, red/500 failed; space 4–32; radius 6/10/14/full). Dark only. Material 3 controls on top of it. |

Type scale, mobile (the desktop styles are 13 px, too small for the phone): app
title 17–18 SemiBold, body 16, row title 15 Medium, secondary 13, caption 12,
terminal 12 mono. Touch targets are at least 44, mostly 48. The mic is 72 in the
dock and 96 on New task.

### Screens (match the Figma frames)

1. **Pair**: scan the QR, or paste address + pairing code. Connect calls
   `/api/ping`, then stores the details.
2. **Inbox**: Needs you / Working / Todo / Done (Done collapsed), All/Work/Personal
   filter, usage strip, and a centered "New task" voice button. Pull to refresh.
   Swipe a row for Archive or Pin.
3. **Agent ("It's asking")**: the question, quick replies (one tap sends), last
   output, and the voice dock. A working agent opens straight into Terminal.
4. **New task**: voice-first, with a Work/Personal toggle, recent folders (from
   `snapshot.dirs`) plus Other..., an editable transcript, a derived title, and
   Start / Save to Todo.
5. **Terminal**: live attach with a keys bar (keyboard, Esc, ^C, Tab, Enter,
   arrows; it scrolls) and a pinned mic. Back detaches only.
6. **Offline**: the cached inbox greyed out, a "Can't reach fedora" banner with
   Retry, and voice falling back to phone speech.

### Folder layout

```
loft-mobile/
  PLAN.md
  app/                      # flutter create --org dev.xaria --platforms android,ios app
    lib/
      main.dart  app.dart (router, theme)
      theme/     tokens.dart  theme.dart
      data/      loft_client.dart  sse.dart  models.dart  pairing_store.dart  outbox.dart
      state/     snapshot.dart  connection.dart  voice.dart
      voice/     recorder.dart  phone_speech.dart  trailing_command.dart
      screens/   pair/  inbox/  agent/  new_task/  terminal/
      widgets/   agent_item.dart  voice_dock.dart  account_toggle.dart
                 usage_strip.dart  keys_bar.dart  offline_banner.dart
      notify/    watcher.dart
    test/        trailing_command_test.dart  sse_test.dart  models_test.dart  widgets/
  tools/fake_loft.py        # canned snapshot + echo voice, for UI work without the real server
```

### Milestones

- **M0, server (touches the Loft server repo):** tailnet listener,
  device tokens, pair/revoke, QR in desktop Loft, m4a voice, `/api/ping`.
- **M1, read-only:** paste-pair, secure storage, SSE inbox with filter and usage,
  offline banner.
- **M2, act:** Agent screen (reply, quick replies, stop, archive), New task with text.
- **M3, voice:** hold/tap recorder, `/api/voice`, the Voice dock states, the
  trailing "send it"/"start it" with Undo, the phone-speech fallback, and the outbox.
- **M4, terminal:** xterm attach, resize, keys bar, mic paste.
- **M5, comfort:** QR scan, "needs you" notifications, haptics, pinned agents.
- **M6, ship:** signed release APK (keys kept outside the repo, as in
  a local keys folder), installed on the phone. iOS comes after Android is in daily use.

### Testing

- **Unit:** the trailing-command regex (shared cases with desktop), the SSE parser
  (chunk boundaries, `: ping`), snapshot model parsing from a saved `/api/state`
  JSON, and outbox retry.
- **Widget:** Voice dock in each state, Agent item, offline banner.
- **Fake server:** `tools/fake_loft.py` serves canned snapshots so UI work doesn't
  depend on live agents.
- **Emulator:** start it with `-gpu swangle_indirect` (it won't render otherwise on
  this machine). Point it at `10.0.2.2:7717` with a device token, which is why M0
  accepts device tokens on loopback. Mic input in the emulator is unreliable, so
  test voice on the phone.
- **Real phone:** once over USB, `adb tcpip 5555`. After that,
  `adb connect <phone tailnet IP>:5555` and `flutter run -d <ip>:5555` work from
  anywhere on the tailnet. Check by hand: pairing by QR, revoke kills the session
  within 2 s, a reply lands in the agent, a terminal with keys, and offline →
  online recovery with Tailscale toggled off and on.
- **Security checks:** `ss -ltnp | grep 7717` shows only 127.0.0.1 and 100.x.y.z.
  Requests from a non-tailnet IP and with a wrong token fail. The desktop token is
  refused on the tailnet listener, and `/` and `/api/pair` return 404 there.

## 4. Open decisions

1. **Needs-you notifications.** (a) A foreground service that keeps SSE open
   (simple and private, with a permanent notification and some battery cost);
   (b) a self-hosted ntfy on the laptop pushing over the tailnet; or (c) no push
   in v1, refresh on open only. Suggested: (a), with a toggle.
2. **Phone permissions.** Full control (start, stop, terminal input) or a narrower
   device scope (read + reply + new task, with Stop and terminal input behind a
   confirm)? Suggested: full control, with confirms on Stop and Archive.
3. **Phone access always on, or only while the desktop switch is on?** Suggested:
   switch, off by default, remembered.
4. **Live words while recording.** Accept "text appears about 1 s after release"
   for v1, or build `/ws/voice` chunked Whisper streaming now?
5. **Tailnet peer allowlist.** Pin the phone by Tailscale node identity
   (`tailscale whois`) on top of the token? Suggested: yes, it is cheap.
6. **iOS.** When, and whether there is an Apple developer account for TestFlight.
