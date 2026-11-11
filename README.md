# Loft Mobile

Phone front end for [Loft](https://github.com/lucerocris/loft): see, start, answer and steer
the Claude Code background agents on your computer, across all your accounts, voice first.
Android first; the Flutter project keeps the iOS folder so iOS can follow.

- Plan and decisions: [PLAN.md](PLAN.md).
- App: `app/` (Flutter, package `dev.xaria.loft`, app name "Loft").
- Server side: Loft's phone access (Tailscale-only listener with per-phone pairing codes).

## Try it

1. On the computer, run Loft and turn on Phone access (phone icon in the header), then Pair a phone.
2. Put the phone on the same Tailscale network.
3. Build and install: `cd app && flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk`.
4. Scan the pairing QR code in the app.

For development without a computer running Loft, `tools/fake_loft.py` serves a fake snapshot
(scenarios: freelancer, two-accounts, solo, legacy) that the emulator reaches at 10.0.2.2.
