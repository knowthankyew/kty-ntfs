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
- [ ] Import upstream `ntfs-3g` source code into `src/core/vendor/`.
- [ ] Strip legacy dependencies:
  - Remove all FUSE (`fuse.h`, `libfuse`) headers, wrappers, and daemon loops.
  - Remove POSIX command-line utilities and unnecessary tools.
- [ ] Implement a clean C abstraction layer for device block I/O (`kty_io.c` / `kty_io.h`) compatible with macOS file descriptors and `FSBlockDeviceResource`.
- [ ] Compile and verify `libkty_ntfs_core.a` static library across `arm64` and `x86_64`.
- [ ] Write a standalone C test runner to verify reading boot sectors and basic $MFT records from a test disk image (`.img`).

---

## Phase 2: Native FSKit Extension Scaffold (`kty-ntfs-fs.appex`)
- [ ] Scaffold the App Extension target targeting `FSUnaryFileSystem`.
- [ ] Implement `FSFileSystemBase` protocols:
  - Volume probing (`probeResource`) to identify NTFS magic bytes (`NTFS    `).
  - Capability reporting (read, write, xattr flags).
- [ ] Implement read-only mounting:
  - Bridge `FSBlockDeviceResource` block reads into `libkty_ntfs_core`.
  - Implement directory lookup (`lookupItem`) and directory enumeration (`enumerateDirectory`).
  - Implement file reading (`readFromFile`).
- [ ] Test mounting an NTFS disk image locally and verifying directory browsing in Finder and Terminal.

---

## Phase 3: Write Pipeline & Journal Synchronization
- [ ] Implement write operations in the FSKit extension:
  - File creation (`createItem`) and deletion (`removeItem`).
  - Write payload handling (`writeToFile`) with sector-aligned cluster allocation.
  - File truncation and renaming.
- [ ] Integrate transaction logging and safety hooks:
  - Synchronous updating of `$LogFile` and `$UsnJrnl`.
  - Implement explicit cache flushing on file close / sync.
  - Safe unmount sequence: verify buffer flush and clean volume dirty bit.

---

## Phase 4: Forensic Hygiene & Policy Engine
- [ ] Implement path-based metadata filtering:
  - Intercept and silently drop write attempts for `.DS_Store`, `.Spotlight-V100`, `.Trashes`, and `.fseventsd`.
  - Implement `--allow-system-metadata` override flag with prominent warning outputs.
- [ ] Extended Attribute (`xattr`) translation:
  - Map macOS `xattrs` into NTFS Alternate Data Streams (ADS).
  - Suppress generation of `._*` AppleDouble sidecar files.
- [ ] Add integrity metadata logging (SHA-256 / BLAKE3 checksum calculations during writes for chain-of-custody).

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
