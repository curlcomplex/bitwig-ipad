# Bitwig on iPad — experimental native host

An independent prototype adapting locally installed ARM64 Bitwig Studio binaries to iPadOS with a UIKit compatibility layer, an iOS Java runtime, and an embedded audio-engine process. It is not a source recompilation of Bitwig and is not affiliated with or endorsed by Bitwig GmbH.

## Current state

Bitwig Studio 6.1.4 has run on a physical iPad mini A17 Pro: the original interface, Poly Synth, clip playback, internal device dragging and speaker output have been exercised. The integrated JIT helper uses a local developer tunnel and trusted device pairing; it remains debugger-assisted internally. No separate debugger app is needed in the tested session. Standalone launch after reboot with the Mac disconnected is not yet qualified.

The main resizable window follows the current iPad scene bounds. The app hides the status bar and extracts its icon from the user's own Bitwig installation at build time. Menus and dialogs retain their own window geometry.

6.1.7 multitouch adaptation is the next work item. The present input bridge maps one finger to mouse input; simultaneous multitouch is not implemented yet.

## Source and local prerequisites

This repository contains the compatibility code, host, development tools and targeted tests. It intentionally excludes Bitwig binaries, JARs, presets, icons, Java runtime binaries, signing material, pairing records, screenshots and device logs. Obtain Bitwig from its publisher and comply with its licence. Demo Mode restrictions are unchanged.

The current development setup uses macOS, Xcode with an iOS SDK, Python 3, XcodeGen, a Java development kit for JNI headers, Apple development signing, and a trusted iPad with Developer Mode enabled. The scripts currently assume Homebrew paths and project-specific signing/bundle identifiers; adjust those for your account.

Local dependencies under `vendor/` are described in THIRD_PARTY.md. This is a development snapshot, not a one-command installer: the iOS Java runtime, embedded helper dependencies, device pairing and signing must be prepared separately. Never commit a pairing file.

The existing build sequence prepares the Java probe bundle metadata, runs `scripts/audit-native-port.py`, builds the audio engine using `scripts/build-native-engine-probe.py --device`, then builds the host:

```sh
python3 scripts/build-native-host.py --device --embedded-tunnel --embedded-engine
```

Generated files belong under `build/` and diagnostics under `evidence/`, both excluded from Git. The icon is generated locally into the build asset catalog.

## Limitations

Saving/exporting remain subject to Bitwig activation and the native save panel is not implemented. Audio input, external audio routes, third-party plug-ins, full hardware-keyboard handling and multitouch are incomplete or unqualified. This prototype does not claim exhaustive crash coverage or production readiness.
