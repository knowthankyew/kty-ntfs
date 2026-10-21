# kty-ntfs

An evidence-grade, native, user-space NTFS read/write storage engine for macOS (Apple Silicon & x86_64).

Part of the **knowthankyew** project.

## Key Features

- **Native macOS 14+ / 15+ (FSKit):** Pure user-space file system extension. No legacy Kernel Extensions (KEXTs), no `macFUSE`, and no need to lower system security to "Reduced Security" mode in Apple Silicon Recovery.
- **Battle-Tested Engine:** Powered by an isolated, headless static build of `libntfs-3g` stripped of legacy FUSE dependencies.
- **Forensic Hygiene by Default:** Automatically suppresses macOS metadata pollution (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, and `._*` AppleDouble files) to preserve clean evidence media.
- **Autonomous System Daemon:** Includes `kty-ntfsd` for automated `DiskArbitration` intercept and mount management, alongside the `kty-ntfs` companion CLI.

## Documentation

- [Architecture Specification](docs/ARCHITECTURE.md)
- [Implementation Roadmap](docs/ROADMAP.md)

## License

GPL-2.0-or-later (inheriting upstream `libntfs-3g` core requirements).
