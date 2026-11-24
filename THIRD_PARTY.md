# Third-party components

- **Bitwig Studio**, Bitwig GmbH: proprietary application supplied by the user. No application binaries, Java archives, presets or branding assets are distributed here. The build extracts the app icon from the local installation.
- **OpenJDK / iOS Java 25**: runtime work from [AngelAuraMC's OpenJDK build](https://github.com/AngelAuraMC/angelauramc-openjdk-build) and [Amethyst iOS](https://github.com/AngelAuraMC/Amethyst-iOS). Local runtime is expected at `vendor/java25-ios`. Respect the upstream runtime licences when obtaining or distributing it. The historical Zero patch is included as development source.
- **Embedded JIT helper source**: the builder reads selected helper files from [Henge](https://github.com/Leviidev/Henge) at `vendor/Henge/ios` (development checkout `3956a9fe0a641a77e75b10cb21a0ec8faac1fb69`). The VM/application is not used by this native host. These upstream helper files are not vendored in this repository.
- **StikJIT**: [StikDebug/StikJIT](https://github.com/StikDebug/StikJIT), currently referenced through `vendor/Husk/src/app/Frameworks/StikJIT.xcframework` from [Husk](https://github.com/Leviidev/Husk). Binary dependencies are not included.
- **LocalDevVPN**, Stossy11 and SideStore Team: the packet-swapping provider is based on [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN), commit `17740a2dfb11cd19a55575aff9aecc74213a3b10`. Its complete licence is retained at `native/LocalDevVPN-LICENSE.txt` and packaged by the builder.
- **idevice**: Rust device utilities use the dependency and versions recorded in `native/pair-device/Cargo.toml` and `Cargo.lock`.

Upstream components retain their respective licences. This repository does not grant rights to Bitwig's software or trademarks.
