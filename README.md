# Bitwig on iPad — experimental native host

An independent prototype adapting locally installed ARM64 Bitwig Studio binaries to iPadOS with a UIKit compatibility layer, an iOS Java runtime, and an embedded audio-engine process. It is not a source recompilation of Bitwig and is not affiliated with or endorsed by Bitwig GmbH.

## Current state

Bitwig Studio 6.1.4 has run on a physical iPad mini A17 Pro: the original interface, Poly Synth, clip playback, internal device dragging and speaker output have been exercised. The integrated JIT helper uses a local developer tunnel and trusted device pairing; it remains debugger-assisted internally. No separate debugger app is needed in the tested session. Standalone launch after reboot with the Mac disconnected is not yet qualified.

The main resizable window follows the current iPad scene bounds. The app hides the status bar and extracts its icon from the user's own Bitwig installation at build time. Menus and dialogs retain their own window geometry.

6.1.7 multitouch work has begun. A local comparison of the official 6.1.7 download against 6.1.4 found seven added native imports and 35 added touch-related strings, including `BWDirectTouchRecognizer`, `handleTouchPressedEvent`, `handleTouchUpdateEvent` and `handleTouchReleasedEvent`. The recognizer subclasses `NSGestureRecognizer` and consumes AppKit touch events. The current UIKit bridge still maps one finger to mouse input; simultaneous multitouch is not implemented yet.

The immediate integration work is to provide the recognizer/touch-event compatibility layer, preserve each finger's identity and phase, and forward UIKit touches into the original Bitwig recognizer. The audio-engine binary also changed: its version-specific LLVM memory-manager addresses must be revalidated before replacing the installed 6.1.4 build. Do not mix a 6.1.7 frontend with the cached 6.1.4 engine.

A repeatable read-only comparison is available:

```sh
python3 scripts/inspect-bitwig-upgrade.py /path/to/6.1.4.app /path/to/6.1.7.app --output evidence/upgrade.json
```

Verified for the current appearance change: device build and strict signature check, installation, a live 1133 × 744-point window at origin zero, and an edge-to-edge screenshot with no status icons. The status-bar test passed during orientation requests, but both captured images remained landscape; portrait resizing is not yet physically qualified.

## Source and local prerequisites

This repository contains the compatibility code, host, development tools and targeted tests. It intentionally excludes Bitwig binaries, JARs, presets, icons, Java runtime binaries, signing material, pairing records, screenshots and device logs. Obtain Bitwig from its publisher and comply with its licence. Demo Mode restrictions are unchanged.

The integrated tunnel uses code based on LocalDevVPN by Stossy11 and the SideStore Team; see THIRD_PARTY.md and its retained licence.

The current development setup uses macOS, Xcode with an iOS SDK, Python 3, XcodeGen, a Java development kit for JNI headers, Apple development signing, and a trusted iPad with Developer Mode enabled. The scripts currently assume Homebrew paths and project-specific signing/bundle identifiers; adjust those for your account.

Local dependencies under `vendor/` are described in THIRD_PARTY.md. This is a development snapshot, not a one-command installer: the iOS Java runtime, embedded helper dependencies, device pairing and signing must be prepared separately. Never commit a pairing file.

The existing build sequence prepares the Java probe bundle metadata, runs `scripts/audit-native-port.py`, builds the audio engine using `scripts/build-native-engine-probe.py --device`, then builds the host:

```sh
python3 scripts/build-native-host.py --device --embedded-tunnel --embedded-engine
```

Generated files belong under `build/` and diagnostics under `evidence/`, both excluded from Git. The icon is generated locally into the build asset catalog.

## Limitations

Saving/exporting remain subject to Bitwig activation and the native save panel is not implemented. Audio input, external audio routes, third-party plug-ins, full hardware-keyboard handling and multitouch are incomplete or unqualified. This prototype does not claim exhaustive crash coverage or production readiness.
