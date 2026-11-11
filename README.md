# Loft Mobile

Phone front end for Loft (`~/cagents/server.py`): see, start, answer and steer
the Claude Code background agents on the laptop, for both accounts (Work =
Ritchie, Personal = lucerocris), voice first. Android first; the Flutter
project keeps the iOS folder so iOS can follow.

- Plan and decisions: [PLAN.md](PLAN.md). Figma: file `4JZHgYBCfSwFEwFIynSTdv`, page Mobile.
- App: `app/` (Flutter, package `dev.xaria.loft`, app name "Loft").
- Server side lives in `~/cagents` (branch `loft-mobile-server`).

## How it connects

Loft on the laptop gets a **Phone access** switch (smartphone icon, top bar).
When on, it adds a second listener bound to the laptop's Tailscale IPv4 only
(never 0.0.0.0). The phone pairs once by scanning the QR (or pasting the
address and code), and then talks plain HTTP/WebSocket inside the tailnet
(WireGuard encrypts it) with `Authorization: Bearer <device token>`.

- Tokens are per phone, stored hashed on the laptop, revocable from the same dialog.
- Each token is pinned to the Tailscale node that first used it.
- The phone keeps the token in Android Keystore (`flutter_secure_storage`).

## Voice

Hold the mic to talk (release to stop, slide left to cancel) or tap it to keep
listening. Audio streams as PCM16 16 kHz to the laptop's `/ws/voice`; words
appear while you speak (faster-whisper small.en partials about every 0.8 s), then a
final pass with the vocabulary hint. End with "send it" (reply) or "start it"
(new task) to submit hands-free; a 2 s Undo shows first. If the laptop can't be
reached, Android's on-device speech takes over ("Phone speech") and sends wait
in an outbox until the laptop is back.

## Needs-you alerts

Menu → Needs-you alerts. A foreground service keeps one SSE connection to the
laptop and posts a local notification when an agent starts waiting. No outside
push service. It shows a quiet permanent notification.

## Develop

```sh
export PATH=$HOME/develop/flutter/bin:$PATH
cd app
flutter analyze && flutter test
flutter build apk --debug          # build/app/outputs/flutter-apk/app-debug.apk
```

Emulator: `~/develop/android-sdk/emulator/emulator -avd folio_test -gpu swangle_indirect`.
The emulator reaches the laptop's Tailscale IP through the host, so it can use
the real phone listener (the peer shows up as the laptop's own tailnet node).
If that ever fails, start the test server with `--dev-loopback-devices` (off by
default) and pair with address `10.0.2.2:<port>`; that flag accepts device
tokens on 127.0.0.1 and must never be used for the live Loft.

Test server next to the live one (never touch 7717):

```sh
cd ~/cagents/.claude/worktrees/mobile
LOFT_CONF_DIR=/tmp/loft-dev-conf python3 server.py --port 7718 --phone-port 7719 --tailnet
python3 -m unittest tests.test_phone_access -v
```

Live words on the emulator (its mic is unreliable): debug builds accept
`--dart-define=LOFT_FAKE_MIC=true`, which streams `files/fake_mic.pcm` from
the app's data dir (PCM16 16 kHz mono) instead of the mic. Ignored in release
builds. Push it with:

```sh
espeak-ng -w /tmp/s.wav "Check the appeal cards. Start it." && ffmpeg -i /tmp/s.wav -f s16le -ac 1 -ar 16000 /tmp/fake_mic.pcm
adb push /tmp/fake_mic.pcm /data/local/tmp/
adb shell "run-as dev.xaria.loft mkdir -p files; run-as dev.xaria.loft cp /data/local/tmp/fake_mic.pcm files/fake_mic.pcm"
```

## Release signing

`app/android/app/build.gradle.kts` signs release builds with
`~/loft-keys/keystore.properties` (`storeFile`, `storePassword`, `keyAlias`,
`keyPassword`) when that file exists, otherwise with the debug key. Keep keys
outside the repo.

Fonts: Geist and Geist Mono (SIL Open Font License), static instances made
from the variable fonts Loft desktop ships.
