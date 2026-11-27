# Bitwig on iPad

An experimental UIKit host for the original ARM64 Bitwig Studio frontend and audio engine. Build it on a Mac with your own copy of Bitwig Studio, then run it in an iPad Simulator or on a development iPad. This independent project is unaffiliated with Bitwig GmbH.

Use the [current branch, `epic/6.1.7-multitouch`](https://github.com/curlcomplex/bitwig-ipad/tree/epic/6.1.7-multitouch). The default branch contains an older implementation.

```sh
git clone --branch epic/6.1.7-multitouch https://github.com/curlcomplex/bitwig-ipad.git
cd bitwig-ipad
```

## Build requirements

- Apple silicon Mac with Xcode, Python 3.10 or newer, and a macOS JDK for JNI headers. Set `BITWIG_JDK_HOME` to choose the JDK explicitly.
- A local ARM64 Bitwig Studio 6.1.4 or 6.1.7 app. The current iPad workflows below target 6.1.7.
- A compatible iOS Java 25 runtime at `vendor/java25-ios` with `lib/`, `conf/`, and `release`. See [runtime sources and local inputs](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md).

```sh
export BITWIG_APP="/path/to/Bitwig Studio 6.1.7.app"
```

Builds read your local binaries, leave the originals intact, and print the output path under `build/`.

## Run in Simulator

Install an ARM64 iPad Simulator runtime in Xcode. Use `xcrun simctl list devices` for local Simulator identifiers.

```sh
python3 scripts/audit-native-port.py
python3 scripts/build-native-java-probe.py
python3 scripts/build-native-host.py --run --simulator <simulator-id>
```

Omit `--run --simulator <simulator-id>` to build without installing or launching.

## Install on an iPad

You need XcodeGen, a trusted iPad with Developer Mode enabled, and Apple development signing that supports App Groups and the Network Extensions capability. The Network Extensions capability requires a supported paid Apple Developer membership. The embedded local tunnel uses a trusted developer pairing for JIT. See [Apple’s capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) and [helper inputs and attribution](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md).

Set the following environment variables for the same target across all build commands. Keep the bundle prefix and groups when updating an existing installation.

| Variable | Value |
| --- | --- |
| `BITWIG_BUNDLE_PREFIX` | Your reverse-DNS prefix. The host identifier is `<prefix>.nativehost`. |
| `BITWIG_DEVELOPMENT_TEAM` | Your Apple Developer team ID. |
| `BITWIG_APP_GROUP` | Registered App Group for project and audio data. |
| `BITWIG_IPC_GROUP` | Registered App Group for named semaphores, at most 14 characters including `group.`. |

```sh
python3 scripts/audit-native-port.py
python3 scripts/build-native-engine-probe.py --device
python3 scripts/build-native-host.py --device --embedded-tunnel --embedded-engine
```

Install the signed `.app` printed by the builder with Xcode’s Devices and Simulators window, or run `xcrun devicectl device install app --device <device-id> "/path/to/BitwigNativeHost.app"`. Copy your existing trusted developer pairing record to the installed app before opening it.

```sh
xcrun devicectl device copy to --device <device-id> \
  --domain-type appDataContainer --domain-identifier "$BITWIG_BUNDLE_PREFIX.nativehost" \
  --source "/path/to/pairing.plist" --destination Documents/pairing.plist
```

Open Bitwig on the iPad and approve the local tunnel when prompted. Keep pairing and signing materials private.

## Use Bitwig

The main workspace fills the scene, while auxiliary windows and supported plug-in editors open in floating panels. The original onscreen keyboard supports multitouch. Caps Lock toggles the computer MIDI keyboard when using a hardware keyboard.

Project saving and export require the applicable Bitwig activation. Use **File → Save** and reopen saved projects from **Recent Projects** on the Dashboard. Use the master meter’s record button to capture the master output, then its folder button to open and preview the WAV. See [compatibility and audio routing](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/docs/compatibility.md).

## Manage prepared plug-ins in Files

Add `--independent-plugins --surge-editor-clap-include /path/to/clap/include` to the iPad host build. Use headers from the [CLAP SDK](https://github.com/free-audio/clap). In Bitwig **Settings → Plug-ins**, select **with Bitwig**.

Prepare supported desktop plug-ins on the Mac with the same Apple Development signing identity used for the host. Pass `--library` to prepare a local library or provide individual bundle paths. Run `python3 scripts/prepare-plugins.py --help` for options and see the [supported FabFilter releases](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/scripts/fabfilter_clap.py).

```sh
python3 scripts/prepare-plugins.py --library /Library/Audio/Plug-Ins \
  --output "$PWD/Prepared Plug-ins" --sign "Apple Development: Your Name"
```

1. Open Bitwig once, then go to **Files → On My iPad → Bitwig → Plug-ins**.
2. Copy each prepared folder directly into **Plug-ins**, keeping its `Package.plist` and contents together.
3. Return to Bitwig to refresh the browser on 6.1.7. Other supported builds pick up folder changes at the next launch.

Remove a plug-in by removing its prepared folder in Files. Loaded instances keep their current resources until the audio engine restarts. Existing prepared installs migrate to the Files folder once. Preparation preserves the original plug-in identities for saved projects, and vendor authorization still applies. Automatic preparation of original desktop bundles added through Files is tracked in [issue #29](https://github.com/curlcomplex/bitwig-ipad/issues/29).

For local builds that bundle supported plug-ins inside the signed app, see the options in `python3 scripts/build-native-host.py --help` and the [supported releases and inputs](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md).

## Choose a Grid DSP rate

For the exact Bitwig Studio 6.1.7 build, add `--grid-rate-overlay` to the iPad host build above. In the Poly Grid, FX Grid, or Note Grid device Inspector, **DSP rate** offers **1×** at the host sample rate and **4×** at the original rate. Each device saves its choice with the project and defaults to **4×**. Custom sources outside the supported profile keep the entire device at **4×**. Unmodified Bitwig opens the project at **4×** and drops the setting if it saves the project again.

At **1×**, oscillators and nonlinear modules can alias more. Modules with their own HQ stages may still oversample. CPU usage depends on the patch. The [Grid setup guide](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/tests/grid-rate/README.md) also covers macOS preparation with Patchbay. The desktop loader has been checked headlessly.

## Source and licensing

The repository provides source for the host and compatibility code. Bitwig Studio, generated apps, and proprietary assets come from your local inputs. See the [MIT license and its scope](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/LICENSE), [third-party notices](https://github.com/curlcomplex/bitwig-ipad/blob/epic/6.1.7-multitouch/THIRD_PARTY.md), and [Bitwig’s terms](https://www.bitwig.com/terms-conditions/).
