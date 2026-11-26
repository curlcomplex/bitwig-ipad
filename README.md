# Bitwig on iPad

An experimental, independent UIKit host for a locally supplied ARM64 Bitwig Studio installation. It runs adapted copies of the original frontend and audio engine with an iOS Java runtime. It is unaffiliated with Bitwig GmbH.

**Current implementation:** [`epic/6.1.7-multitouch`](https://github.com/curlcomplex/bitwig-ipad/tree/epic/6.1.7-multitouch). The default branch is an older implementation. Check out the current branch before running either build below.

```sh
git fetch origin
git switch epic/6.1.7-multitouch
```

The repository contains development source. The build reads Bitwig and other binary dependencies from local installations, leaves the originals intact, and writes generated apps and diagnostics under ignored directories. The project’s original compatibility code is under MIT. Third-party components and materials retain their applicable terms. [License scope](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/LICENSE) · [Third-party notices](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md) · [Bitwig terms](https://www.bitwig.com/terms-conditions/)

## How it works

```mermaid
flowchart LR
    UIKit["UIKit host and input"] --> Bridge["AppKit compatibility bridge"]
    Java["iOS Java runtime and original Bitwig frontend"] <--> Bridge
    Java <-->|App Group files and IPC| Engine["Original ARM64 engine in its own extension"]
    Engine --> Audio["Shared PCM ring and host RemoteIO output"]
```

The device host uses an embedded JIT helper with a trusted local developer pairing. The local tunnel is based on **LocalDevVPN by Stossy11 and the SideStore Team**. [Tunnel license and attribution](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md)

## Verified on Bitwig Studio 6.1.7

| Area | Evidence |
| --- | --- |
| Touch and windows | The original onscreen keyboard was tested hands-on with multiple fingers on a physical iPad mini A17 Pro. The Simulator exercised independent finger release, scene-switch cancellation, and an Arranger radial-menu gesture. The main workspace fills the scene, and auxiliary dialogs preserve their own size. |
| Keyboard and mouse | Tested physical secondary click and Cmd+D clip duplication. Caps Lock toggles the original computer MIDI keyboard. A physical A key played and released a note when enabled and stayed quiet when disabled. |
| Audio and MIDI | Built-in microphone recording with simultaneous speaker output was verified. Audio through a Zoom U-44 was tested hands-on, and its MIDI ports appeared. MIDI data transfer remains untested. A saved clip also played over AirPods in hands-free mode, and a live switch to the speaker and back reconnected the open project. |
| Projects and recording | A saved, activated project reopened with its instrument and edited MIDI notes intact. The original Master Recording produced a WAV that remained available after reopening and played in Bitwig’s Preview Player. |
| Original plug-in editors | Scripted input on a physical iPad exercised the current opt-in builds of Surge XT, CHOW Tape Model, Xfer OTT, and Neural Amp Modeler. Parameter edits, Close Plug-in, project save and reopen, and audio playback were checked. NAM also restored a model and impulse response imported through its editor. |

The device launch is debugger-assisted and uses a trusted local developer pairing. Standalone launch after a reboot remains unverified. Project saving and exporting require the applicable Bitwig activation. [Compatibility details and test commands](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/docs/compatibility.md)

## Build a Simulator host

Use an Apple-silicon Mac, Xcode with an ARM64 iPad Simulator runtime, Python 3.10+, and a macOS JDK for JNI headers. The current build was checked with Xcode 27.2. Supply a local ARM64 Bitwig Studio 6.1.4 or 6.1.7 app and a compatible iOS Java 25 runtime in `vendor/java25-ios`. The runtime directory needs `lib/`, `conf/`, and `release`. Set `BITWIG_JDK_HOME` to override `JAVA_HOME` and macOS JDK discovery. [Runtime provenance](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md)

```sh
export BITWIG_APP="/path/to/Bitwig Studio 6.1.7.app"
python3 scripts/audit-native-port.py
python3 scripts/build-native-java-probe.py
python3 scripts/build-native-host.py
```

The builders print their output paths under `build/<version>/<source-key>/`. A running Simulator is required only to install or test the app. Use `python3 scripts/build-native-host.py --run --simulator <id>` to build, install and launch, or set `BITWIG_SIMULATOR_ID`. You can find local IDs with `xcrun simctl list devices`. The Simulator uses a neutral app identifier unless you set `BITWIG_BUNDLE_PREFIX`.

## Build for a development iPad

Device builds additionally require XcodeGen, a trusted iPad with Developer Mode enabled, the local helper inputs in [THIRD_PARTY.md](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md), and Apple development signing with the required entitlements. The embedded packet tunnel uses the Network Extensions capability, which requires a supported paid program membership. The host and engine extension must both have access to the two registered App Groups. [Apple capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) · [App Group entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups)

Set these variables locally for your own provisioning. The bundle suffixes for the app, engine, JIT helper and tunnel derive from one prefix. Keep the existing prefix and groups when updating an install.

| Variable | Purpose |
| --- | --- |
| `BITWIG_BUNDLE_PREFIX` | Your reverse-DNS prefix. The host is `<prefix>.nativehost`. |
| `BITWIG_DEVELOPMENT_TEAM` | Your Apple Developer team identifier. |
| `BITWIG_APP_GROUP` | Registered group for the shared project and audio data. |
| `BITWIG_IPC_GROUP` | Registered group for named semaphores, at most 14 characters including `group.`. |

```sh
python3 scripts/audit-native-port.py
python3 scripts/build-native-engine-probe.py --device
python3 scripts/build-native-host.py --device --embedded-tunnel --embedded-engine
```

Use the same `BITWIG_APP` and identity configuration for all three commands. The build does not install the app on an iPad. Provision trust and pairing for the device locally. The existing helper reads `Documents/pairing.plist` from the installed app. Keep pairing records, signing materials, logs, generated files, and proprietary assets outside tracked source.

## Projects and Master Recording

File → Save stores new projects in `BitwigUser/Projects` in the app's shared container. Reopen them from Recent Projects on the Bitwig Dashboard. Use the master meter's record button to capture the master output, and the adjacent folder button to open the project's `master-recordings` folder and preview the recording.

## Experimental original plug-in editors

The following opt-ins use matching locally installed desktop plug-ins. In Bitwig Settings → Plug-ins, select **with Bitwig**.

### Surge XT and CHOW Tape Model CLAP

Pass `--surge-clap "/path/to/Surge XT.clap"` to the iPad build with `--embedded-engine` to include a private copy of the supported Surge XT 1.3.4 desktop release. The build checks the original image, adapts its ARM64 slice, and signs it locally. This build uses Bitwig's device parameters by default.

In the scripted iPad check, Surge’s original editor accepted Patch Browser text, opened its secondary-click menu, and dismissed the menu on Escape or an outside click. A Macro 1 drag updated Bitwig’s parameter and restored after project reopen. Surge’s original numeric **Edit Value** dialog updates the plug-in’s internal macro without sending the host notification that its drag path sends.

Run `python3 tests/surge-clap-probe.py --help` using the [Surge CLAP probe](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/tests/surge-clap-probe.py) for the isolated Simulator check that reads the CLAP descriptor, changes and restores a parameter, and verifies note-on output and note-off release.

The opt-in `--surge-editor-clap-include /path/to/clap/include` build enables the original Surge editor. The engine renders the live plug-in instance and the foreground app relays touches from its editor panel. The panel routes hardware keys and secondary clicks to the original editor. Surge’s context menus stay within the editor panel at the same scale. The same CLAP SDK include directory is used by `tests/surge-clap-probe.py --editor`, which checks isolated drawing, parameter edits, resizing, and cleanup alongside state and audio. Physical editor integration is experimental.

The same probe accepts `--chow-editor` with the official CHOW Tape Model 2.11.0 desktop CLAP to exercise the shared editor adapter with a second JUCE plug-in in Simulator. Add `--chow-clap "/path/to/CHOWTapeModel.clap"` to the same iPad editor build to package that release alongside Surge XT.

### Xfer OTT VST3

Pass `--ott-vst3 "/path/to/OTT.vst3"` to the build with `--device`, `--embedded-engine` and a supported local installation of Xfer OTT 1.3.1. The build adapts the original ARM64 executable, keeps the original editor resources and signs the private copy locally. Find OTT from Xfer Records under Audio FX and open its native editor from the device panel.

### Neural Amp Modeler VST3

Pass `--nam-vst3 "/path/to/NeuralAmpModeler.vst3"` with `--device` and `--embedded-engine` to include the supported local Neural Amp Modeler 0.7.13 release. The build adapts the original ARM64 plug-in and compiles its matching upstream MetalNanoVG shader for iPadOS using the Xcode Metal toolchain. The original editor renders with Metal in the engine process and shares its completed frames with the foreground app. Its model and impulse response controls open the iPad Files picker. Selected `.nam` and `.wav` files are copied into the shared Bitwig user directory so saved projects can reopen them. The physical check presented the real Files picker and used scripted selection through its picker callback, then verified both assets after reopening the project.

## Source checks

Run `python3 tests/local-config.py` for [configuration validation](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/tests/local-config.py) and `python3 scripts/check-public-source.py` to [check a committed snapshot](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/scripts/check-public-source.py) for unexpected file types and common private-data patterns. The check reports categories only. It does not inspect external files or earlier history. Build artifacts and compatibility reports stay local. [Compatibility inventory, diagnostics, and targeted tests](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/docs/compatibility.md)
