# kty-ntfs Operations & Administration Runbook

`kty-ntfs` is an evidence-grade, native, user-space NTFS read/write storage engine and orchestration layer for macOS 14+ (Sonoma) and macOS 15+ (Sequoia) supporting both Apple Silicon (`arm64`) and Intel (`x86_64`).

This operational guide provides administrators, forensic analysts, and developers with instructions for building, signing, installing, operating, troubleshooting, and verifying `kty-ntfs`.

---

## 1. Architectural & Security Overview

`kty-ntfs` operates entirely in user space, completely replacing obsolete Kernel Extensions (KEXTs) and third-party FUSE layers (`macFUSE`):

- **Headless Static Engine (`libkty_ntfs_core.a`):** An isolated static library compiling upstream `ntfs-3g` without FUSE headers, wrapped by a fail-closed POSIX block I/O abstraction (`kty_io.c`).
- **Autonomous Daemon (`kty-ntfsd`):** A root background daemon that hooks into Apple's `DiskArbitration` framework, intercepts the kernel's default read-only NTFS mounts via `DADissenterCreate(kDAReturnBusy)`, and serves client requests over an Apple Darwin Mach messaging IPC channel (`com.knowthankyew.ntfsd`).
- **Companion CLI (`kty-ntfs`):** A command-line frontend providing volume listing, manual mounting, journal-synchronized unmounting, and real-time status inspection.
- **FSKit App Extension (`kty-ntfs-fs.appex`):** Conforms to Apple's `FSUnaryFileSystem` protocol to bridge block resources into user space.
- **Forensic Hygiene by Default:** Automatically suppresses macOS host metadata (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, and `._*` AppleDouble files) in volatile memory tombstones. Zero disk clusters are allocated and zero dirty-bit toggles occur on the NTFS volume.
- **Cryptographic Chain-of-Custody:** Hardware-accelerated SHA-256 and streaming BLAKE3 tree hashes are calculated on writes and published directly into NTFS Alternate Data Streams (`kty.integrity.sha256` and `kty.integrity.blake3`).
- **Zero-Egress Isolation:** Statically audited to contain zero BSD sockets, networking symbols, or telemetry (`nm -u` clean).

---

## 2. Code Signing & Local Evaluation Model

### Current Phase 7 State: Local Self-Signed & Ad-Hoc Evaluation

To allow immediate local evaluation, development, and testing before Apple Developer Account registration is finalized (scheduled for Phase 8), `kty-ntfs` supports two local signing configurations:

1. **Ad-Hoc Signing (Default):**
   - Invoked automatically during `make all` via `scripts/codesign-adhoc.sh`.
   - Uses identity `-` with the hardened runtime flag (`--options runtime`).
   - Requires **no keychain interaction, no certificates, and no administrative approval**.
   - Fully enables the CLI (`kty-ntfs`), daemon (`kty-ntfsd`), and test harnesses across all local disks and images.

2. **Local Self-Signed Identity:**
   - Generated via `scripts/create-self-signed-cert.sh`.
   - Creates a 2048-bit RSA certificate with Code Signing Extended Key Usage (`codeSigning`) in your login Keychain (`kty-ntfs-local`).
   - Configured via environment variable:
     ```bash
     export KTY_CODESIGN_IDENTITY="kty-ntfs-local"
     make clean && make all
     ```

### macOS FSKit Extension System Constraints

> [!IMPORTANT]
> **System-Wide Finder Auto-Mounting vs. CLI/Daemon Usage:**  
> On macOS 14+ (Sonoma) and macOS 15+ (Sequoia), Apple's `fskitd` daemon enforces that system-wide App Extensions (`.appex`) registered for automatic Finder volume mounting must be signed with an official Apple Developer ID certificate bearing the restricted `com.apple.developer.fskit.fsmodule` entitlement (or require System Integrity Protection to be disabled via `csrutil disable` in Recovery).  
>
> In the current Phase 7 release, `kty-ntfs` operates autonomously via `kty-ntfsd` and `kty-ntfs`, allowing complete read/write access, forensic metadata filtering, ADS stream inspection, and automated disk orchestration **without compromising macOS System Integrity Protection (SIP)**. Official Apple Developer ID signing and notarization are scheduled for Phase 8.

---

## 3. Installation & Lifecycle Management

### Prerequisites
- macOS 14.0 or higher
- Xcode Command Line Tools (`xcode-select --install`)
- Administrative (`sudo`) privileges for system installation

### Building the Project
```bash
git clone https://github.com/knowthankyew/kty-ntfs.git
cd kty-ntfs
make -j4 all
```

### System Installation (`make install`)
To install the binaries, App Extension bundle, and `launchd` system daemon:

```bash
sudo make install
```

This invokes `scripts/install.sh`, performing the following automated steps:
1. Verifies code signatures of `kty-ntfs`, `kty-ntfsd`, and `kty-ntfs-fs.appex`.
2. Installs binaries to `/usr/local/bin/kty-ntfs` and `/usr/local/bin/kty-ntfsd` (`755`).
3. Installs the FSKit extension bundle to `/Library/Filesystems/kty-ntfs-fs.appex` (`root:wheel`).
4. Installs the LaunchDaemon definition to `/Library/LaunchDaemons/com.knowthankyew.ntfsd.plist` (`644`).
5. Bootstraps and activates the daemon via `launchctl bootstrap system`.
6. Performs an immediate health check via `kty-ntfs status`.

#### Custom Installation Prefix
To install to an alternative location (e.g. `/opt/kty`):
```bash
PREFIX=/opt/kty sudo make install
```

### Homebrew Installation
A standalone Homebrew formula is provided in `Formula/kty-ntfs.rb`:

```bash
# Install directly from local formula
brew install --build-from-source Formula/kty-ntfs.rb

# Start the background daemon service via brew
sudo brew services start kty-ntfs
```

### Managing the Background Daemon (`launchd`)
The daemon is registered under the service identifier `com.knowthankyew.ntfsd`.

```bash
# Check daemon registration
sudo launchctl list com.knowthankyew.ntfsd

# Restart the running daemon
sudo launchctl kickstart -k system/com.knowthankyew.ntfsd

# Stop / unload the daemon service
sudo launchctl bootout system/com.knowthankyew.ntfsd

# Start / bootstrap the daemon service
sudo launchctl bootstrap system /Library/LaunchDaemons/com.knowthankyew.ntfsd.plist
```

### Uninstallation (`make uninstall`)
To remove all binaries, system plists, and extension bundles:

```bash
sudo make uninstall
```

To also purge all daemon logs from `/var/log/`:
```bash
sudo ./scripts/uninstall.sh --purge-logs
```

---

## 4. Companion CLI (`kty-ntfs`) Reference

The companion CLI communicates with `kty-ntfsd` via local Mach IPC messaging.

### Query Daemon Status
```bash
kty-ntfs status
```
Example Output:
```text
=== kty-ntfs Status ===
Daemon PID:       48192
Uptime:           3600 seconds
Forensic Hygiene: ACTIVE (Host metadata suppressed)
Mounted Volumes:  1
Total Tx Handled: 124
Total Bytes I/O:  104857600 (100.00 MB)
```

JSON output for scripting and orchestration:
```bash
kty-ntfs status --json
```

### List Attached NTFS Partitions
```bash
kty-ntfs list
```
Example Output:
```text
=== Attached NTFS Volumes ===
Device:       /dev/disk4s1
BSD Name:     disk4s1
Volume Name:  EVIDENCE_01
Capacity:     64.00 GB
Mount Point:  /Volumes/EVIDENCE_01
Forensic:     CLEAN (Metadata suppressed)
Status:       MOUNTED (Read/Write)
```

JSON output:
```bash
kty-ntfs list --json
```

### Mount an NTFS Device
```bash
# Mount with forensic hygiene (default)
kty-ntfs mount /dev/disk4s1

# Mount to a specific directory target
kty-ntfs mount /dev/disk4s1 --target /Volumes/MyNTFS

# Mount in read-only mode (write protection)
kty-ntfs mount /dev/disk4s1 --readonly

# Mount with forensic suppression overridden (NOT RECOMMENDED for forensics)
kty-ntfs mount /dev/disk4s1 --allow-system-metadata
```

### Unmount an NTFS Device
Flushes all pending cluster buffers, recalculates integrity metadata, marks the NTFS dirty bit clean, and synchronizes the journal:

```bash
# Unmount by device node
kty-ntfs unmount /dev/disk4s1

# Unmount by mount point
kty-ntfs unmount /Volumes/EVIDENCE_01
```

---

## 5. Forensic Hygiene & Integrity Verification

### Metadata Suppression Behavior
When forensic hygiene is enabled (the default), `kty-ntfs` intercepts and drops all OS-level indexing, thumbnailing, and trash artifacts:
- `.DS_Store` (Finder desktop service layout)
- `.Spotlight-V100` (Spotlight indexing database)
- `.Trashes` (macOS trash bin)
- `.fseventsd` (File system event logging)
- `.TemporaryItems` (Temporary scratch directory)
- `._*` (AppleDouble resource fork sidecars)

These writes are answered with synthetic POSIX `0` success responses in memory tombstones. They never touch disk sectors, allocate clusters, or alter MFT timestamps.

### Verifying Alternate Data Streams (ADS)
Extended attributes and cryptographic hashes are written directly to NTFS Alternate Data Streams.

#### On macOS:
```bash
# List all extended attributes / ADS streams on a file
xattr -l /Volumes/EVIDENCE_01/case_document.docx

# Read the SHA-256 tree hash
xattr -p kty.integrity.sha256 /Volumes/EVIDENCE_01/case_document.docx

# Read the BLAKE3 tree hash
xattr -p kty.integrity.blake3 /Volumes/EVIDENCE_01/case_document.docx
```

#### On Windows (PowerShell):
```powershell
# List Alternate Data Streams
Get-Item -Path "E:\case_document.docx" -Stream *

# Inspect recorded SHA-256 stream
Get-Content -Path "E:\case_document.docx" -Stream kty.integrity.sha256

# Verify bit-for-bit file integrity
(Get-FileHash -Path "E:\case_document.docx" -Algorithm SHA256).Hash
```

---

## 6. Diagnostics & Troubleshooting

### Log Inspection
The daemon logs all DiskArbitration events, mount transitions, and Mach XPC requests to standard system locations:
- Standard log: `/var/log/kty-ntfsd.log`
- Error log: `/var/log/kty-ntfsd.err`

To follow daemon activity in real time:
```bash
tail -f /var/log/kty-ntfsd.log /var/log/kty-ntfsd.err
```

### Common Issues & Resolutions

| Issue | Root Cause | Resolution |
| :--- | :--- | :--- |
| `kty-ntfs: command not found` | `/usr/local/bin` not in `$PATH` | Add `export PATH="/usr/local/bin:$PATH"` to your `~/.zshrc` or run with full path. |
| `Error: Failed to connect to kty-ntfsd` | Daemon is not running or crashed | Check service status with `sudo launchctl list com.knowthankyew.ntfsd`. Check `/var/log/kty-ntfsd.err` for startup errors. |
| `Dissenter conflict / volume busy` | Another process is holding an exclusive handle | Run `lsof /dev/diskXsY` to inspect conflicting processes. Run `diskutil unmount /dev/diskXsY` before mounting. |
| `NTFS Dirty bit set on mount` | Previous unmount on Windows or Mac was ungraceful | `kty-ntfs` safely mounts dirty volumes in read-only mode by default to prevent corruption. Run `chkdsk /f` on Windows to cleanly repair the volume. |
| `Permission denied on /dev/diskXsY` | Calling user lacks raw disk access | Ensure `kty-ntfsd` is running as `root` via `launchd` or `sudo`. |

---

## 7. Quality Gates & Test Suites

The repository contains three primary test suites that must pass before any deployment:

```bash
# 1. Run all unit, integration, and invariant tests
make test

# 2. Run under AddressSanitizer (ASan) and UndefinedBehaviorSanitizer (UBSan)
make asan

# 3. Run the forensic torture test harness (stress allocation & recovery)
make torture

# 4. Generate standalone Windows 11 cross-platform verification bundle
make generate-bundle
```

---

## 8. Roadmap: Transition to Phase 8 (Distribution)

The next major milestone for `kty-ntfs` will transition from local self-signed evaluation to production distribution:
1. **Apple Developer Enrollment:** Acquire an Apple Developer Program Team ID.
2. **FSKit Entitlement Authorization:** Submit request to Apple for the restricted `com.apple.developer.fskit.fsmodule` entitlement.
3. **Automated Notarization:** Integrate `xcrun notarytool` into release workflows.
4. **Distribution Packaging:** Publish signed and notarized `.pkg` installers and official Homebrew Cask taps.
