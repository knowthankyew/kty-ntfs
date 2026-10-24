# kty-ntfs Implementation Roadmap

This roadmap outlines the phased development of `kty-ntfs`, taking it from an isolated core C engine to a fully autonomous, evidence-grade NTFS background daemon and CLI for macOS 14+ (Sonoma) and macOS 15+ (Sequoia).

---

## Phase 0: Workspace Setup & Build Infrastructure
- [x] Establish repository structure:
  - `src/core/` (C engine)
  - `src/fskit/` (Swift/ObjC FSKit Extension)
  - `src/daemon/` (DiskArbitration daemon `kty-ntfsd`)
  - `src/cli/` (CLI frontend `kty-ntfs`)
  - `tests/` (Unit and integration harness)
- [x] Configure build system (universal Mach-O output for `arm64` and `x86_64`).
- [x] Setup local ad-hoc code-signing configuration and entitlements for FSKit development.

---

## Phase 1: Headless Engine Isolation (`libkty_ntfs_core`)
- [x] Import upstream `ntfs-3g` source code into `src/core/vendor/`.
- [x] Strip legacy dependencies:
  - Remove all FUSE (`fuse.h`, `libfuse`) headers, wrappers, and daemon loops.
  - Remove POSIX command-line utilities and unnecessary tools.
- [x] Implement a clean C abstraction layer for device block I/O (`kty_io.c` / `kty_io.h`) compatible with macOS file descriptors and `FSBlockDeviceResource`.
- [x] Compile and verify `libkty_ntfs_core.a` static library across `arm64` and `x86_64`.
- [x] Write a standalone C test runner to verify reading boot sectors and basic $MFT records from a test disk image (`.img`).

---

## Phase 2: Native FSKit Extension Scaffold (`kty-ntfs-fs.appex`)
- [x] Scaffold the App Extension target targeting `FSUnaryFileSystem`.
- [x] Implement `FSFileSystemBase` protocols:
  - Volume probing (`probeResource`) to identify NTFS magic bytes (`NTFS    `) with deterministic container UUIDs.
  - Capability reporting (read, write, persistent IDs, journals).
- [x] Implement read-only mounting and core I/O bridge:
  - Bridge `FSBlockDeviceResource` block reads/writes into `libkty_ntfs_core`.
  - Implement directory lookup (`lookupItemNamed:`) and directory enumeration (`enumerateDirectory:` with proper EOF pagination).
  - Implement file reading (`readFromFile:intoBuffer:`).
- [x] Assemble `kty-ntfs-fs.appex` bundle with `Info.plist` and ad-hoc codesigning with App Sandbox entitlements.
- [x] Write bridge test suite (`tests/test_fskit_bridge.m`) verifying probing, capability reporting, pagination, and C bridge I/O under `make test` and `make asan`.

---

## Phase 3: Write Pipeline & Journal Synchronization
- [x] Implement write operations in the FSKit extension:
  - File creation (`createItem`) and deletion (`removeItem`) with tail cluster reclamation.
  - Write payload handling (`writeContents:toFile:atOffset:`) with dynamic contiguous cluster allocation, non-tail relocation, and state rollbacks.
  - Defensive EOF bounds enforcement, clamping, and negative offset validation.
  - File truncation (`truncateToSize:`) and POSIX-compliant renaming (`renameItem:`) with directory cycle checks.
- [x] Integrate transaction logging and safety hooks:
  - Synchronous updating of dirty state, transaction counters, and journal sync (`synchronizeWithFlags:`).
  - Explicit block cache and device sync flushing via `d_ops->sync`.
  - Safe unmount and teardown sequence (`cleanup`): verified buffer flush and clean volume dirty bit.

---

## Phase 4: Forensic Hygiene & Policy Engine
- [x] Implement path-based metadata filtering:
  - Intercept and silently drop write attempts for `.DS_Store`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, and `._*` AppleDouble sidecars into memory tombstones.
  - Zero disk clusters allocated and zero dirty-bit toggles for suppressed metadata; excluded from directory enumeration.
  - Implement `--allow-system-metadata` override flag with prominent warning outputs.
- [x] Extended Attribute (`xattr`) translation:
  - Full conformance to `FSVolumeXattrOperations`: get, set, list, and delete extended attributes.
  - Map macOS `xattrs` into NTFS Alternate Data Streams (ADS) and suppress AppleDouble `._*` file generation.
- [x] Add integrity metadata logging (SHA-256 / BLAKE3 checksum calculations during writes for chain-of-custody):
  - Hardware-accelerated CommonCrypto SHA-256 and official specification BLAKE3 tree-hashing engine in C.
  - Automated calculation and publication of `kty.integrity.sha256` and `kty.integrity.blake3` into Alternate Data Streams.
  - Bounded 64 KB streaming recomputation on segmented writes and stale hash invalidation on truncation.

---

## Phase 5: Autonomous Daemon (`kty-ntfsd`) & CLI (`kty-ntfs`)
- [x] Develop `kty-ntfsd`:
  - Initialize `DiskArbitration` session with thread-safe run loop management.
  - Listen for NTFS partition GUIDs (`EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`) and volume identifiers.
  - Intercept the system's default read-only mount via `DADissenterCreate(kDAReturnBusy)` and route to the `kty-ntfs` engine.
  - Provide an Apple XPC interface over Mach messaging (`com.knowthankyew.ntfsd`) with zero networking symbols for status, mounts, unmounts, and metrics.
- [x] Develop `kty-ntfs` CLI:
  - `kty-ntfs list`: Show attached NTFS volumes, capacity, and forensic hygiene status.
  - `kty-ntfs mount <device> [options]`: Manual mount invocation with forensic flags (`--allow-system-metadata`, `--readonly`, `--target`).
  - `kty-ntfs unmount <target>`: Graceful flush, journal sync, and unmount with standardized path handling.
  - `kty-ntfs status`: Query daemon status, PID, uptime, forensic cleanliness mode, and active transaction/byte metrics.
  - Fail-closed IPC error handling, non-blocking offline error responses, and CLI timeouts.
- [x] Create `launchd` service plist (`com.knowthankyew.ntfsd.plist`) for automated background execution of `kty-ntfsd`.

---

## Phase 6: Forensic Torture Testing & Validation
- [x] **Cross-Platform Compatibility Harness:**
  - Automated high-throughput torture harness (`test_torture`) testing deep hierarchies, multi-file allocations, and random mutations.
  - Native Windows 11/10 automated validation suite (`scripts/verify-windows.ps1` & `scripts/verify-windows.bat`).
  - Automated generation of standalone evidence test bundles (`make generate-bundle` -> `build/kty_test_evidence.img`).
  - Operational runbook and verification checklist (`docs/WINDOWS_VALIDATION.md`).
  - Validation assertions: clean mount without "Scan and fix" dialogs, 0 `chkdsk` filesystem/index errors, and 0 dirty bit flags.
- [x] **Cryptographic Hash Verification:**
  - Streaming multi-chunk BLAKE3 and SHA-256 tree hashing across 64 KB boundaries.
  - Automatic publishing and verification of Alternate Data Streams (`kty.integrity.sha256` and `kty.integrity.blake3`).
  - Verified bit-for-bit payload matching against `manifest.json` and `checksums.sha256`.
- [x] **Failure Recovery & Sudden Disconnect Testing:**
  - Simulated surprise disk removal and abrupt un-synced process termination during active dirty writes.
  - Validated fail-closed error propagation (`EIO`) and safe volume remount recovery.

---

## Phase 7: Local Hardening, Packaging, Installation & Operational Runbooks
- [x] **Local Code Signing & Identity Automation:**
  - Configurable identity signing support via `KTY_CODESIGN_IDENTITY` in `scripts/codesign-adhoc.sh` (defaulting to ad-hoc `-`).
  - Automated local self-signed certificate generation script (`scripts/create-self-signed-cert.sh`) with code signing EKU and Keychain import.
  - Non-interactive ad-hoc signing for rapid local CLI, daemon, and harness testing without keychain authorization dialogs.
- [x] **Standalone Packaging & System Integration:**
  - Automated installer (`scripts/install.sh`) supporting binary, appex, and launchd plist installation with root/wheel permissions and configurable `PREFIX`.
  - Standalone uninstaller (`scripts/uninstall.sh`) for clean daemon unload, binary removal, and optional log purging.
  - Homebrew formula (`Formula/kty-ntfs.rb`) for source builds and brew service management.
  - Makefile integration (`make install` and `make uninstall`).
- [x] **Documentation & Operational Runbooks:**
  - Comprehensive operational runbook (`docs/OPERATIONS.md`) detailing setup, daemon lifecycle, CLI operations, forensic hygiene policies, ADS integrity verification, troubleshooting, and self-signed certificate management.
  - Updated `README.md` with installation commands, local self-signing options, and operational runbook links.

---

## Phase 8: Apple Developer Account Registration, Entitlements & System VFS Mounting
- [ ] **Apple Developer Program Enrollment:**
  - Register Apple Developer Program account and acquire Team ID.
  - Generate official Apple Developer ID Application code signing certificates.
- [ ] **Restricted Entitlement Provisioning (`com.apple.developer.fskit.fsmodule`):**
  - Submit request and secure Apple authorization for the restricted `com.apple.developer.fskit.fsmodule` entitlement.
  - **Finder GUI Mount Enablement**: On macOS 14+ (Sonoma) and macOS 15+ (Sequoia), Apple's `fskitd` requires this entitlement to publish third-party file system mount points into `/Volumes` and Finder. Without this entitlement, self-signed/ad-hoc builds cannot mount into the macOS kernel VFS unless System Integrity Protection (SIP) is disabled (`csrutil disable`).
  - Integrate Apple provisioning profiles into release build pipeline.
- [ ] **Automated Notarization Pipeline:**
  - Configure automated Apple Notarization pipeline (`xcrun notarytool` / `stapler`).
  - Strict hardened runtime verification without ad-hoc overrides.
- [ ] **Distribution Packaging:**
  - Create signed and notarized `.pkg` / `.dmg` installers for end-user distribution.
  - Provide official signed Homebrew Cask tap and explore Mac App Store submission.

---

## Phase 9: Native macOS Menu Bar UI Companion (`kty-ntfs-menu`)
- [ ] **Native AppKit / SwiftUI Status Bar Application:**
  - Lightweight menu bar extra (`kty-ntfs-menu.app`) living in the macOS status bar.
  - Real-time disk inventory querying `com.knowthankyew.ntfsd` over XPC.
  - Per-volume cards showing capacity, status, and forensic hygiene mode.
- [ ] **Interactive Volume Selector & Auto-Mount Toggles:**
  - Checkbox per detected volume: `[✓] Auto-Mount with Write Support`.
  - Persists configuration directly to `/Library/Preferences/com.knowthankyew.ntfsd.plist`.
  - Manual "Mount Read/Write", "Mount Read-Only", and "Unmount" action buttons.
- [ ] **Visual Fast Startup Safety Diagnostics & Guidance:**
  - Visual status badges: 🟢 Clean (Fast Startup Inactive) vs. ⚠️ Fast Startup Active.
  - Interactive diagnostic sheet displaying step-by-step Windows Control Panel instructions, `powercfg /h off` copy button, and cold restart shortcuts when Fast Startup is detected.


