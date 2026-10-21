# kty-ntfs

An evidence-grade, native, user-space NTFS read/write storage engine for macOS (Apple Silicon & x86_64).

Part of the **knowthankyew** portfolio.

## Key Features

- **Native macOS 14+ / 15+ (FSKit):** Pure user-space file system extension. Zero legacy Kernel Extensions (KEXTs), zero `macFUSE`, and no need to degrade system security to "Reduced Security" mode in Apple Silicon Recovery.
- **Battle-Tested Engine:** Powered by an isolated, headless static build of `libntfs-3g` stripped of legacy FUSE dependencies.
- **Forensic Hygiene by Default:** Automatically suppresses macOS metadata pollution (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, and `._*` AppleDouble files) to preserve clean evidence media.
- **Autonomous System Daemon:** Includes `kty-ntfsd` for automated `DiskArbitration` intercept and mount management, alongside the `kty-ntfs` companion CLI.
- **Zero Network Egress:** Audited and verified with zero network imports, framework links, or socket invocations.

## Documentation

- [Architecture Specification](docs/ARCHITECTURE.md)
- [Implementation Roadmap](docs/ROADMAP.md)
- [Legal, Privacy, and Attribution Notice](NOTICE.md)

## Licensing Distinction & Portfolio Architecture

> [!IMPORTANT]
> **Portfolio Licensing Notice:**  
> The core repositories across the `knowthankyew` portfolio (e.g. `knowthankyew-extension`, `lease-audit`, `careCheck`, `mac-screen-record`) are released under the permissive **MIT License**.
>
> In contrast, `kty-ntfs` incorporates and statically links against the upstream `libntfs-3g` filesystem engine and is therefore distributed under the **GNU General Public License v2 (GPL-2.0-or-later)**.
>
> **Process Boundary Isolation:**  
> `kty-ntfs` is intentionally architected as an autonomous background daemon (`kty-ntfsd`) and standalone companion CLI (`kty-ntfs`). MIT-licensed tools within `knowthankyew` and third-party tools interact with `kty-ntfs` strictly across standard operating system process boundaries (CLI invocations, POSIX filesystem mounts, or XPC), ensuring clear architectural separation and preventing reciprocal GPL license contagion into the MIT portfolio engines.
