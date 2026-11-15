# Handoff: first Loft Mobile build in TestFlight (for Sai)

Status (2026-11-15): the Apple side is set up. What's missing is a build, and building an iOS app
needs a Mac with Xcode. Goal: get a build of branch `ios-testflight` into TestFlight so Cris can install
it on his iPhone.

## What's already done

| What | Value |
|---|---|
| Apple Developer team | Cris Lawrence Lucero, Team ID `WD8496XKN8` (the same team your `feat/ios-access` commit set) |
| Bundle ID (App ID) | `com.lucerocris.loft`, explicit, no extra capabilities. **Don't use `dev.xaria.loft` or anything with "xaria".** |
| App Store Connect app | "Loft Agents" (the name "Loft" was taken), Apple ID `6835088072`, SKU `loft-mobile`, iOS only |
| Home-screen name | Still "Loft" (`CFBundleDisplayName`) |
| TestFlight | Internal group "Me", automatic distribution on, Cris is the tester. Every build that finishes processing goes to the group automatically |
| Branch `ios-testflight` | GitHub `main` (includes your `feat/ios-access`) + bundle ID switched to `com.lucerocris.loft` + `ITSAppUsesNonExemptEncryption = false`, so uploads skip the export-compliance question |

Android and the desktop app still use `dev.xaria.loft`. Leave them alone for now.

## 0. Access (Cris does this first)

You need to be a user on the team. Cris invites you in App Store Connect › Users and Access with
the **App Manager** role and **Access to Certificates, Identifiers & Profiles** turned on. Accept the
email invite. If Xcode later says it can't create a distribution certificate, Cris switches you to
**Admin**.

## 1. Mac setup

- Latest Xcode from the App Store (Apple only accepts uploads built with the current SDK), opened
  once so it installs its components.
- Flutter stable that satisfies `sdk: ^3.11.1` in `app/pubspec.yaml`, plus CocoaPods.
- Xcode › Settings › Accounts: add your Apple ID and check that team "Cris Lawrence Lucero" is listed.

## 2. Build

```sh
git fetch origin && git checkout ios-testflight
cd app
flutter pub get
(cd ios && pod install)
open ios/Runner.xcworkspace
```

In Xcode, select the Runner target › Signing & Capabilities:
- Automatically manage signing: on
- Team: Cris Lawrence Lucero
- Bundle Identifier: `com.lucerocris.loft` (already set, just check it)

If signing shows no errors, close Xcode and build the archive:

```sh
flutter build ipa --release --build-number=1
```

Every upload needs a higher build number than the last one (1, 2, 3, ...). The version stays
`1.0.0` from `pubspec.yaml` until we change it.

## 3. Upload

Pick one:
- **Xcode**: open `build/ios/archive/Runner.xcarchive` (Window › Organizer), Distribute App ›
  App Store Connect › Upload.
- **Transporter** app (free from the Mac App Store): drag in `build/ios/ipa/*.ipa` and Deliver.

Apple processes the build in roughly 5 to 30 minutes and sends an email. After that, it shows up in
App Store Connect › Loft Agents › TestFlight, and group "Me" gets it automatically.

Add yourself to group "Me" too (TestFlight › Me › Testers › +) if you want it on your phone.

## 4. Check on a phone

1. Install the **TestFlight** app on the iPhone and accept the invite (sent to the tester's Apple ID email).
2. Install Loft. The phone needs **Tailscale** connected to the same tailnet as the laptop.
3. On the laptop, turn on phone access in Loft (Phone icon) and pair with the QR code.
4. Check: the agent inbox loads, opening an agent shows chat/terminal, the mic works, and the
   camera and local network permission prompts show the right text.

## Done when

- A build is "Ready to Test" in TestFlight › Me.
- Cris has it installed from TestFlight and it pairs with Loft.
- Anything you had to change in the Xcode project is committed on `ios-testflight` (open a PR
  to `main`).

## Notes and gotchas

- `NSAllowsArbitraryLoads` is on because Loft talks plain http/ws over Tailscale (WireGuard
  already encrypts it). That's fine for internal testers, who don't need App Review. External
  testers (people outside the team) need a Beta App Review, and Apple may ask us to justify it.
- "Missing compliance" on a build means the Info.plist key didn't make it into the build. Answer
  "None of the algorithms mentioned" in App Store Connect and let Cris know.
- A "bundle ID not available" error means the build isn't using `com.lucerocris.loft`. Check the
  Runner target, not RunnerTests.
- Later: we can upload from GitHub Actions (macOS runner + an App Store Connect API key) so
  TestFlight builds don't need your Mac. Not part of this handoff.
