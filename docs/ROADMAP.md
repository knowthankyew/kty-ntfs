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
- [ ] Develop `kty-ntfsd`:
  - Initialize `DiskArbitration` session.
  - Listen for NTFS partition GUIDs (`EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`).
  - Intercept the system's default read-only mount and route to `kty-ntfs-fs.appex`.
  - Provide an XPC / local socket interface for status and manual unmounts.
- [ ] Develop `kty-ntfs` CLI:
  - `kty-ntfs list`: Show attached NTFS volumes and their mount status.
  - `kty-ntfs mount <device> <target>`: Manual mount invocation with forensic flags.
  - `kty-ntfs unmount <target>`: Graceful flush and unmount.
  - `kty-ntfs status`: Query daemon status and active transaction metrics.
- [ ] Create `launchd` service plist for automated background execution of `kty-ntfsd`.

---

## Phase 6: Forensic Torture Testing & Validation
- [ ] **Cross-Platform Compatibility Harness:**
  - Write multi-gigabyte forensic test bundles on macOS via `kty-ntfs`.
  - Move the physical media to a native Windows 11 system.
  - Assert that Windows mounts cleanly without "Scan and fix" dialogs.
  - Run `chkdsk /f` and verify zero errors, orphan sectors, or MFT index corruptions.
- [ ] **Cryptographic Hash Verification:**
  - Verify that file payloads match bit-for-bit (BLAKE3 / SHA-256) between macOS and Windows.
- [ ] **Failure Recovery & Sudden Disconnect Testing:**
  - Simulate surprise disk removal during active writes; verify journal replay and consistency upon remount.

---

## Phase 7: Hardening, Packaging & Release
- [ ] Code signing transition:
  - Package with Apple Developer ID certificate.
  - Apply `com.apple.developer.fskit.fsmodule` entitlement.
  - Configure notarization pipeline.
- [ ] Create standalone installation package / brew formula for the daemon and CLI.
- [ ] Documentation, operational runbooks, and integration examples for the `knowthankyew` suite.
