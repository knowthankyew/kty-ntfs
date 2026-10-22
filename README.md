# kty-ntfs

An evidence-grade, native, user-space NTFS read/write storage engine for macOS (Apple Silicon & x86_64).

Part of the **knowthankyew** portfolio.

---

## Key Features

- **Native macOS 14+ / 15+ (FSKit):** Pure user-space file system extension. Zero legacy Kernel Extensions (KEXTs), zero `macFUSE`, and no need to degrade system security to "Reduced Security" mode in Apple Silicon Recovery.
- **Battle-Tested Engine:** Powered by an isolated, headless static build of `libntfs-3g` stripped of legacy FUSE dependencies and bridged to Apple's modern FSKit architecture.
- **Forensic Hygiene by Default:** Automatically intercepts and suppresses host metadata pollution (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, and `._*` AppleDouble files) in volatile memory tombstones without allocating disk clusters or toggling the NTFS dirty bit.
- **Chain-of-Custody Cryptography:** Automatic SHA-256 and BLAKE3 tree hashing calculated in real time and recorded directly into NTFS Alternate Data Streams (`kty.integrity.sha256` and `kty.integrity.blake3`).
- **Autonomous System Daemon:** Background daemon (`kty-ntfsd`) managing `DiskArbitration` auto-mount interception and Mach XPC messaging, accompanied by a companion CLI (`kty-ntfs`).
- **Zero Network Egress:** Audited and statically verified to contain zero networking symbols, sockets, or telemetry (`nm -u` clean).

---

## Current Status: Testable Today vs. Phase 7 Release

| Component | Status | How to Test Today |
| :--- | :---: | :--- |
| **Headless NTFS-3G Engine** | **Ready** | Unit tested via `build/bin/test_ntfs_core` (read/write, cluster allocation, BLAKE3/SHA-256). |
| **FSKit Extension Bridge** | **Ready** | Integration tested via `build/bin/test_fskit_bridge` (metadata tombstones, ADS xattrs, journal sync). |
| **Autonomous Daemon (`kty-ntfsd`)** | **Ready** | Runnable executable (`build/bin/kty-ntfsd`) handling local Mach XPC & DiskArbitration. |
| **Companion CLI (`kty-ntfs`)** | **Ready** | Command-line tool (`build/bin/kty-ntfs`) supporting `status`, `list`, `mount`, and `unmount`. |
| **Torture & Cross-Platform Validation** | **Phase 6** | Multi-gigabyte continuous stress harness, simulated surprise disconnects, and Windows 11 `chkdsk` parity. |
| **System-Wide Finder Auto-Mounting** | **Phase 7** | Requires Apple Developer ID signing and Apple-approved `com.apple.developer.fskit.fsmodule` entitlement. |

> [!NOTE]
> **Ad-Hoc Signing vs. System-Wide Finder Integration:**  
> To prevent system instability, macOS 14+ enforces that system-wide FSKit extensions registered with `fskitd` for Finder auto-mounting must be signed with an Apple Developer ID certificate carrying the restricted `com.apple.developer.fskit.fsmodule` entitlement (or require SIP disabled in Recovery via `csrutil disable`).  
> 
> During development (Phases 0–6), all binaries use **local ad-hoc codesigning**. You can fully run, test, and benchmark the daemon, CLI, cryptographic engine, and filesystem bridge immediately without modifying macOS security policies.

---

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or macOS 15.0+ (Sequoia)
- Apple Silicon (`arm64`) or Intel (`x86_64`)
- Xcode Command Line Tools (`xcode-select --install`)

### 1. Build the Repository

Clone the repository and build the universal binaries:

```bash
cd kty-ntfs

# Build all libraries, extensions, daemon, CLI, and test suites
make -j4
```

This compiles universal fat binaries supporting both `arm64` and `x86_64` in `build/bin/`:
- `build/bin/kty-ntfsd` (Autonomous background daemon)
- `build/bin/kty-ntfs` (Companion CLI tool)
- `build/bin/kty-ntfs-fs.appex` (FSKit file system extension bundle)
- `build/lib/libkty_ntfs_core.a` (Headless static NTFS engine)

### 2. Run the Quality Gates & Test Suites

Execute the comprehensive unit and integration test suite:

```bash
# Run all tests, invariant audits, and licensing checks
make test
```

To run the full suite under AddressSanitizer and UndefinedBehaviorSanitizer:

```bash
# Verify 100% memory safety and absence of undefined behavior
make asan
```

### 3. Testing the Daemon and CLI

You can run the daemon directly in a terminal session and interact with it via the CLI:

#### Terminal 1: Launch the Daemon
```bash
./build/bin/kty-ntfsd
```
Output:
```text
[kty-ntfsd] Starting autonomous NTFS daemon (PID: 12345)...
[kty-ntfsd] Mach service: com.knowthankyew.ntfsd
[kty-ntfsd] Forensic hygiene default: ON (host metadata suppressed)
[kty-ntfsd] Daemon operational. Entering run loop.
```

#### Terminal 2: Run CLI Commands
```bash
# Query daemon status, uptime, and forensic metrics
./build/bin/kty-ntfs status

# Output in JSON format
./build/bin/kty-ntfs status --json

# List attached NTFS partitions and mount status
./build/bin/kty-ntfs list

# Show command help and forensic usage flags
./build/bin/kty-ntfs help
```

---

## Documentation

- [Architecture Specification](docs/ARCHITECTURE.md)
- [Implementation Roadmap](docs/ROADMAP.md)
- [Legal, Privacy, and Attribution Notice](NOTICE.md)

---

## Licensing Distinction & Portfolio Architecture

> [!IMPORTANT]
> **Portfolio Licensing Notice:**  
> The core repositories across the `knowthankyew` portfolio (e.g. `knowthankyew-extension`, `lease-audit`, `careCheck`, `mac-screen-record`) are released under the permissive **MIT License**.
>
> In contrast, `kty-ntfs` incorporates and statically links against the upstream `libntfs-3g` filesystem engine and is therefore distributed under the **GNU General Public License v2 (GPL-2.0-or-later)**.
>
> **Process Boundary Isolation:**  
> `kty-ntfs` is intentionally architected as an autonomous background daemon (`kty-ntfsd`) and standalone companion CLI (`kty-ntfs`). MIT-licensed tools within `knowthankyew` and third-party tools interact with `kty-ntfs` strictly across standard operating system process boundaries (CLI invocations, POSIX filesystem mounts, or XPC), ensuring clear architectural separation and preventing reciprocal GPL license contagion into the MIT portfolio engines.
