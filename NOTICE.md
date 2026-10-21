# Legal, Privacy, and Third-Party Attribution Notice

**kty-ntfs**  
Copyright © 2026 knowthankyew and contributors  
Repository: [https://github.com/knowthankyew/kty-ntfs](https://github.com/knowthankyew/kty-ntfs)

---

## 1. Portfolio Licensing Distinction & Process Boundary Isolation

> [!IMPORTANT]
> **License Model:** GNU General Public License v2 (GPL-2.0-or-later)  
> While the broader `knowthankyew` portfolio defaults to the permissive **MIT License**, `kty-ntfs` incorporates and statically links against the upstream `libntfs-3g` engine and is released under **GPL-2.0-or-later**.
>
> **Architectural Boundary:**  
> To protect the permissive MIT licensing of client reality engines (`knowthankyew-extension`, `mac-screen-record`, `lease-audit`, `careCheck`, etc.), `kty-ntfs` operates strictly as an autonomous background daemon (`kty-ntfsd`) and companion command-line utility (`kty-ntfs`). External tools and scripts invoke `kty-ntfs` exclusively across standard POSIX process boundaries and filesystem mounts, preserving clean license separation across the portfolio.

---

## 2. Functional Scope Notice
`kty-ntfs` is a native, user-space NTFS read/write storage engine and orchestration layer engineered for macOS 14+ (Sonoma) and macOS 15+ (Sequoia) across Apple Silicon (`arm64`) and Intel (`x86_64`). Developed within the `knowthankyew` ecosystem, it provides a trusted, auditable path for writing evidence, forensic images, memory dumps, and logs to NTFS volumes without compromising host security policies or contaminating destination media.

## 3. Consumer Privacy Defaults & Air-Gap Invariant
This software conforms to the `knowthankyew` Consumer-Safe Zero-Egress specification (KTY Invariant 1):
- **Zero Network Egress (`deny`):** Application code does not import or invoke networking APIs (`URLSession`, `Network.framework`, `CFNetwork`), establish BSD socket connections (`socket`, `connect`, `sys/socket.h`), or execute outbound network requests. Statically verified during the build pipeline via `make verify-invariants` and `scripts/audit-claims.py`.
- **Zero Cloud Persistence:** File contents and filesystem metadata are never uploaded to remote servers or third-party cloud services.
- **Zero Remote Telemetry:** The application bundles zero analytics SDKs, trackers, or remote telemetry pipelines. Diagnostics are handled exclusively through Apple's local unified logging subsystem (`os.Logger`).
- **Forensic Cleanliness by Default:** Operating system metadata artifacts (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, and AppleDouble `._*` sidecars) are suppressed by default to prevent evidentiary contamination.

## 4. Third-Party & Framework Attribution
- **NTFS-3G / libntfs-3g:** Underlying low-level NTFS filesystem engine, developed by Tuxera and open-source contributors (GPL-2.0-or-later).
- **Apple FSKit & DiskArbitration:** macOS native user-space filesystem and disk arbitration frameworks.

## 5. Declared macOS Entitlements Justification

All macOS permission keys declared in `src/fskit/entitlements.plist` are restricted strictly to local user-space filesystem hosting:

| Key / Entitlement | Target | Plain-English Justification |
| :--- | :--- | :--- |
| `com.apple.developer.fskit.fsmodule` | `kty-ntfs-fs.appex` | Required by Apple's FSKit subsystem to register and host a user-space filesystem extension. |
| `com.apple.security.app-sandbox` | `kty-ntfs-fs.appex` | Enforces Apple ExtensionKit sandbox confinement on the filesystem provider. |

See [LICENSE](./LICENSE) for the full GNU General Public License v2 terms.
