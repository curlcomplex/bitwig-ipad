# Compatibility inventory and verification

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
  --profile-version 6.1.7 \
  --output evidence/native-compat.json
```

The inventory discovers native files by header in each bundle and its Java archives, detects ARM64 Mach-O slices, and records unsupported formats and architectures. Both originals are evaluated against the supplied bridge profile. Record its version with `--profile-version`. Bundle replacement layers, mapped host imports, the device engine, and optional files carry separate roles. The inventory reads native declarations from each JAR classfile, including versioned entries. JNI searches for the short export name before the descriptor-qualified long name. Candidates identify the original source binaries. Runtime image selection, classpath variants, and the iOS JVM’s exports are outside that name match. Entries without a matching export may be registered at runtime or resolved through another mechanism.

Add `--simulator <booted-device>` for system method inheritance and type encodings from an ARM64 iOS Simulator. Selector references list candidate declaration owners. Direct calls with an attributed or locally inferred receiver list their inheritance chain and confidence. The report counts direct dispatch instructions and direct calls to selected lookup APIs. Receiver merges, indirect calls, forwarding, and runtime strings can escape the static pass. The counts describe inspected files, classfiles, and instructions.

Launch the host with `--native-compat-trace` for optional diagnostics. It records unrecognized selectors on bridge classes, selected native loader results, and unsupported bridge operations while retaining their original responses. Each participating source file records up to 128 events and marks truncation. Capability probes and vendor indirect lookups can go unobserved. HotSpot writes a rotating `native-compat-jvm.log` for library loading and JNI method resolution. Use `--runtime-version 6.1.7 --jvm-trace /path/to/native-compat-jvm.log` with the inventory to correlate Java owner and method names. Repeat `--jvm-trace` for retained rotations from the same run. Inspect library events in the raw logs. JNI overloads and method descriptors remain unverified by the runtime names alone. Keep all reports and traces local.

The 6.1.4 and 6.1.7 audits each found 125 recognized native candidates. Each inspected 49 ARM64 Mach-O slices. A further 41 candidates lacked the ARM64 slice and 35 used other formats. The four Java archives per release contained 66,496 and 66,697 parsed classfiles, with 627 and 630 native declarations. Of those declarations, 45 per release lacked a matching original export name. The two desktop JIMAGE containers per release are replaced by the iOS JRE and were left uninspected. In the JNI images, the static pass found receiver evidence for 136 of 1,911 and 169 of 2,087 decoded direct dispatch instructions. It identified 31 direct lookup calls in each JNI image. In two retained 6.1.7 Simulator runtime logs, 106 owner-and-method names matched bundled declarations.

The 6.1.4 window crash came from `BWWindow` calling the missing inherited frame constraint during a move. The same call also appears in its fullscreen-exit handler, and both sites are present in 6.1.7. The bridge constrains vertical placement to the iPad scene and preserves horizontal placement and the host's adaptive fullscreen policy. The simulator geometry test exercises that inherited method against the compiled bridge.

The bridge now supplies the superclass defaults for `BWView`’s live-resize notifications. UIKit scene layout continues to own resizing. The named app-local pasteboard supports the original declaration and lazy owner path, including binary representations and appended items. File → Open now supplies the inherited panel preference for creating directories. The native Files UI controls directory management. The unresolved `CGFontCreateWithPlatformFont` import is in Cairo's legacy ATS font path, which has no observed caller in the supported host.

The engine report records a null dereference in the original engine's render callback about 25 ms after the frontend aborted. The engine event thread was also in its disconnect handler. Whether teardown invalidated the render graph is still unproven.

### Original 6.1.7 Simulator workflows

| Workflow | Evidence and boundary |
| --- | --- |
| Demo startup | Original frontend entered Demo Mode. The JVM log recorded original native links and the host's Cocoa text-input adapter registration. |
| Editing | The original Arranger displayed a newly created clip after the opt-in mouse-handler replay. An exploratory direct double tap did not produce the same edit in that state. |
| Menus and project lifecycle | Original File menu opened. Close returned to the Dashboard and New Project restored the workspace. XCTest reached the native Files picker and returned to the original project after dismissal. The selection run reached the Bitwig folder listing, but automation could not expose the local project fixture for selection. |
| Touch, dragging and presentation | The preceding 6.1.7 touch branch exercised simultaneous contacts and staggered release, stationary radial hold and clip movement, background cancellation and resume, the profile popup, and fullscreen caption drag and scene resizing. |
| Engine loader | The preceding 6.1.7 Simulator probe entered the original ARM64 engine on port 0, reached the no-server connection attempt and returned. Integrated engine DSP, PCM, and the active-render teardown fault remain open for physical verification. |

Use `scripts/test-native-host-ui.py --simulator <id> --compat-workflow file-picker` from an open landscape Tablet Demo workspace for the File → Open dismissal check. For original Arranger mouse-handler replay, launch with `--native-ui-automation`, switch to Arranger, and invoke `scripts/native-host-control.py click --simulator <id> --x 414 --y 113 --count 2` on an empty first track at the matching zoom. Compare the rendered workspace before and after the operation. The controller invokes original mouse handlers through the development bridge. UIKit touch contact evidence is recorded separately.

Run `python3 tests/compat-discovery.py` to check classfile parsing and JNI name escaping. The standalone bridge regression can run with tracing off or on:

```sh
mkdir -p build
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc \
  tests/compat-boundary.m -framework UIKit -framework Foundation -framework CoreGraphics \
  -o build/compat-boundary
xcrun simctl spawn <id> "$PWD/build/compat-boundary" /path/to/libBitwigUIKit.dylib
xcrun simctl spawn <id> "$PWD/build/compat-boundary" /path/to/libBitwigUIKit.dylib --native-compat-trace
```

The earlier fullscreen and icon update was installed and checked with a live 1133 × 744-point window at origin zero and an edge-to-edge screenshot with no status icons. Both captures from the status-bar rotation check remained in landscape. Physical portrait behavior and the new frame-constraint fix still need their own device evidence.

After building the simulator host, point the routing test at its compiled bridge:

```sh
FRAMEWORKS="$PWD/build/6.1.7/SOURCE_KEY/native-host/Frameworks"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
  -fobjc-arc tests/direct-touch-routing.m -framework UIKit -framework Foundation \
  -L"$FRAMEWORKS" -lBitwigUIKit -Wl,-rpath,"$FRAMEWORKS" -o build/direct-touch-routing
xcrun simctl spawn booted "$PWD/build/direct-touch-routing"
```

For device input checks, launch the development host with `--native-touch-trace` to log recognizer attachment and UIKit contact phases. Use XCUITest to check simultaneous UIKit delivery and hands-on input to check the original keyboard and radial gestures on the iPad. CoreDevice remote-control input is unavailable on the tested iPadOS 26.6 build.
