# Bitwig on iPad — experimental native host

An independent prototype adapting locally installed ARM64 Bitwig Studio binaries to iPadOS with a UIKit compatibility layer, an iOS Java runtime, and an embedded audio-engine process. It is not a source recompilation of Bitwig and is not affiliated with or endorsed by Bitwig GmbH.

## Current state

Bitwig Studio 6.1.4 has run on a physical iPad mini A17 Pro: the original interface, Poly Synth, clip playback, internal device dragging and speaker output have been exercised. The integrated JIT helper uses a local developer tunnel and trusted device pairing; it remains debugger-assisted internally. No separate debugger app is needed in the tested session. Standalone launch after reboot with the Mac disconnected is not yet qualified.

The main resizable window follows the current iPad scene bounds. The app hides the status bar and extracts its icon from the user's own Bitwig installation at build time. Menus and dialogs retain their own window geometry.

The host accepts a locally supplied ARM64 Bitwig Studio 6.1.7 bundle. The bridge connects UIKit direct contacts to the original `BWDirectTouchRecognizer` with per-contact identity, coordinates and phases, including cancellation. Indirect pointer input retains the mouse route. The legacy 6.1.4 bundle remains the default. Each engine uses an LLVM ABI profile checked against its loaded Mach-O UUID and original callback slots.

A repeatable read-only comparison is available:

```sh
python3 scripts/inspect-bitwig-upgrade.py /path/to/6.1.4.app /path/to/6.1.7.app --output evidence/upgrade.json
```

After building the device host and engine probe, compare both local ARM64 app bundles against that build's compiled bridges and the iPhoneOS SDK:

```sh
python3 scripts/inventory-native-compat.py /path/to/6.1.4.app /path/to/6.1.7.app \
  --frameworks build/6.1.7/SOURCE_KEY/native-host-tunnel/DerivedData/Build/Products/Debug-iphoneos/BitwigNativeHost.app/Frameworks \
  --jni-mappings evidence/6.1.7/SOURCE_KEY/native-host-device-library-mappings.json \
  --engine-mappings evidence/6.1.7/SOURCE_KEY/native-engine-device-adaptation.json \
  --output evidence/native-compat.json
```

Add `--simulator <booted-device>` for system Objective-C method declarations, inheritance and type encodings from an ARM64 iOS Simulator. The report checks mapped dependencies and their re-exports, separates strong imports from weak-definition coalescing entries, and records when a provider cannot be inspected. Objective-C selector references list possible owners from inspected metadata. Explicitly attributed direct calls carry the caller, dispatch kind and inheritance chain. Other calls remain ambiguous. An export or matching selector name alone cannot establish ABI or behavior. Dynamic dispatch, forwarding and selector names built at runtime can escape this inventory. Keep the generated report local.

The 6.1.4 window crash came from `BWWindow` calling the missing inherited frame constraint during a move. The same call also appears in its fullscreen-exit handler, and both sites are present in 6.1.7. The bridge constrains vertical placement to the iPad scene and preserves horizontal placement and the host's adaptive fullscreen policy. The simulator geometry test exercises that inherited method against the compiled bridge.

The audit also found two missing superclass live-resize callbacks on `BWView`. The host resizes its UIKit scene through layout callbacks. The original desktop live-resize sequence has no established caller in the iPad host. The unresolved `CGFontCreateWithPlatformFont` import is in Cairo's legacy ATS font path. Its use in the supported host has not been observed.

The engine report records a null dereference in the original engine's render callback about 25 ms after the frontend aborted. Connection teardown is a hypothesis. Reproducing the callback fault with engine lifecycle evidence is required to establish its cause.

The earlier fullscreen and icon update was installed and checked with a live 1133 × 744-point window at origin zero and an edge-to-edge screenshot with no status icons. Both captures from the status-bar rotation check remained in landscape. Physical portrait behavior and the new frame-constraint fix still need their own device evidence.

## Source and local prerequisites

This repository contains the compatibility code, host, development tools and targeted tests. It intentionally excludes Bitwig binaries, JARs, presets, icons, Java runtime binaries, signing material, pairing records, screenshots and device logs. Obtain Bitwig from its publisher and comply with its licence. Demo Mode restrictions are unchanged.

The integrated tunnel uses code based on LocalDevVPN by Stossy11 and the SideStore Team; see THIRD_PARTY.md and its retained licence.

The current development setup uses macOS, Xcode with an iOS SDK, Python 3, XcodeGen, a Java development kit for JNI headers, Apple development signing, and a trusted iPad with Developer Mode enabled. The scripts currently assume Homebrew paths and project-specific signing/bundle identifiers; adjust those for your account.

Local dependencies under `vendor/` are described in THIRD_PARTY.md. This is a development snapshot, not a one-command installer: the iOS Java runtime, embedded helper dependencies, device pairing and signing must be prepared separately. Never commit a pairing file.

To build the 6.1.7 device host, point all three commands at the same local app:

```sh
export BITWIG_APP="/path/to/Bitwig Studio 6.1.7.app"
python3 scripts/audit-native-port.py
python3 scripts/build-native-engine-probe.py --device
python3 scripts/build-native-host.py --device --embedded-tunnel --embedded-engine
```

The audit, engine probe, Java simulator probe and host also accept `--bitwig-app`. Omit both the flag and `BITWIG_APP` to use `/Applications/Bitwig Studio 6.1.4.app`. For a simulator host, run `scripts/build-native-java-probe.py` before building the host. Device builds use the local iOS Java runtime directly.

Builds and diagnostics are isolated under `build/<version>/<source-key>/` and `evidence/<version>/<source-key>/`. The source key is derived from the resolved app path. The builder prints the output location. The host verifies its cached audit and engine adaptation against the selected binaries. Both output directories are excluded from Git. The icon is generated locally into the build asset catalog.

After building the simulator host, point the routing test at its compiled bridge:

```sh
FRAMEWORKS="$PWD/build/6.1.7/SOURCE_KEY/native-host/Frameworks"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
  -fobjc-arc tests/direct-touch-routing.m -framework UIKit -framework Foundation \
  -L"$FRAMEWORKS" -lBitwigUIKit -Wl,-rpath,"$FRAMEWORKS" -o build/direct-touch-routing
xcrun simctl spawn booted "$PWD/build/direct-touch-routing"
```

For device input checks, launch the development host with `--native-touch-trace` to log recognizer attachment and accepted UIKit contact phases. The existing `tap-screen` tool accepts timed contact frames on a trusted device. Each frame includes every still-active contact and any releases, using normalized native digitizer coordinates:

```sh
tap-screen "$BITWIG_DEVICE_UDID" --frames \
  '0:0,20000,40000,down;1,26000,40000,down' \
  '700:0,20000,40000,up;1,26000,40000,down' \
  '400:1,26000,40000,up'
```

## Limitations

Saving/exporting remain subject to Bitwig activation and the native save panel is not implemented. Audio input, external audio routes, third-party plug-ins, full hardware-keyboard handling and physical 6.1.7 multitouch are unqualified. This prototype does not claim exhaustive crash coverage or production readiness.
