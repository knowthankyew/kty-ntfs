# kty-ntfs Architecture

## 1. Overview & Objective

`kty-ntfs` is a native, user-space NTFS read/write storage engine and orchestration layer engineered for macOS 14+ (Sonoma) and macOS 15+ (Sequoia) across Apple Silicon (`arm64`) and Intel (`x86_64`).

Developed within the `knowthankyew` ecosystem, `kty-ntfs` provides a trusted, auditable path for writing evidence, forensic images, memory dumps, and logs to NTFS volumes without compromising host security policies (zero Kernel Extensions, no "Reduced Security" mode) or contaminating destination media with macOS metadata artifacts.

The project is structured as an **autonomous background daemon (`kty-ntfsd`)** and a **companion CLI tool (`kty-ntfs`)** usable by any script, forensic pipeline, or manual workflow on the system.

---

## 2. Core Decisions & Baseline Requirements

* **Target Platforms:** macOS 14.0+ (Sonoma) and macOS 15.0+ (Sequoia). Legacy VFS kext compatibility (Ventura and earlier) is explicitly out of scope.
* **Architecture:** Universal Mach-O (`arm64` + `x86_64`).
* **Security & Sandboxing:** Zero-KEXT. Built entirely on Apple's modern **FSKit** framework. Runs in user space without requiring system reboot or Recovery Mode (1TR) security degradation.
* **Signing Model:** Ad-hoc local code-signing during development and internal testing; prepared for Apple Developer ID + `com.apple.developer.fskit.fsmodule` entitlement upon distribution.
* **Forensic Cleanliness by Default:** The engine intercepts and suppresses OS clutter (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, and AppleDouble `._*` sidecars) by default. A `--allow-system-metadata` flag exists but outputs explicit evidentiary contamination warnings when invoked.

---

## 3. High-Level System Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Consumers / Invokers                            │
│  - knowthankyew Evidence Pipelines                                     │
│  - System CLI (`kty-ntfs mount /dev/disk4s1 /Volumes/Evidence`)        │
│  - Direct automated disk writes from third-party tools                 │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│              Component 3: Daemon & CLI (Swift)                         │
│  - `kty-ntfsd`: Background daemon managing DiskArbitration sessions    │
│  - Auto-claims NTFS block devices (prevents default read-only mount)   │
│  - `kty-ntfs`: CLI client for explicit mount, unmount, status, inspect │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ IPC / XPC Service Calls
┌───────────────────────────────────▼────────────────────────────────────┐
│              Component 2: FSKit File System Extension (.appex)         │
│  - Conforms to `FSUnaryFileSystem` & `FSBlockDeviceResource`           │
│  - Pure user-space execution under Apple's modern FSKit subsystem      │
│  - Policy Engine: Suppresses .DS_Store, maps xattrs to NTFS ADS        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Direct C FFI Bridge
┌───────────────────────────────────▼────────────────────────────────────┐
│              Component 1: Headless libntfs-3g Engine (C)               │
│  - Isolated, statically-linked C core (`libkty_ntfs_core.a`)           │
│  - Stripped of all FUSE dependencies and legacy CLI plumbing           │
│  - Direct block I/O translation to `FSBlockDeviceResource`             │
│  - Synchronous $LogFile & USN journal updates (chkdsk-clean)           │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Component Details

### 4.1. Component 1: Headless `libntfs-3g` Core (`libkty_ntfs_core.a`)
Rather than relying on `ntfs-3g` as an external binary or through `macFUSE`, the low-level NTFS parsing engine is compiled as a standalone static library.

* **Capabilities:**
  * Byte-level parsing of the Master File Table (`$MFT`).
  * B-tree index maintenance for directories.
  * Transaction logging (`$LogFile`) and Update Sequence Number (`$UsnJrnl`) consistency.
  * Support for sparse files, volume dirty bit management, and sector-aligned writes.
* **Modifications from Upstream:**
  * Stripped of all `fuse.h` and POSIX daemon wrappers.
  * Replaced low-level device I/O abstractions (`unix_io`) with direct bridges to macOS `FSBlockDeviceResource` descriptors.
  * Hardened memory allocation policies and boundary checks.

### 4.2. Component 2: Native FSKit Extension (`kty-ntfs-fs.appex`)
Apple’s modern user-space file system mechanism. It replaces traditional VFS kernel extensions and provides a standardized API for block-device filesystems.

* **Protocols Implemented:**
  * `FSUnaryFileSystem`: Handles single-volume mounting lifecycle.
  * `FSUnaryFileSystemOperations`: Handles resource probing (`probeResource`), loading (`loadResource`), and unloading (`unloadResource`).
  * `FSVolumeOperations`: Inode lookups, file creation, item removal, and volume metadata.
  * `FSVolumeReadWriteOperations`: File data reading, cluster allocation, writes, and cache sync.
  * `FSVolumeXattrOperations`: Extended attributes translation to NTFS Alternate Data Streams (ADS).
  * `FSVolumeRenameOperations`: Safe item rename and atomic directory restructuring.

### 4.3. Component 3: Forensic Hygiene & Policy Engine
In digital evidence preservation, writing to a destination disk must not inadvertently modify timestamps, create arbitrary system files, or leave corrupt transaction states.

1. **System Metadata Suppression (Default ON):**
   * Drops requests from Finder or Spotlight to write `.DS_Store`, `.Spotlight-V100`, `.fseventsd`, and `.Trashes`.
   * When enabled, Finder cannot litter the root directory of the destination volume.
   * If disabled via `--allow-system-metadata`, `kty-ntfs` logs a high-severity warning indicating that the volume is receiving non-forensic host modifications.
2. **Alternate Data Stream (ADS) Mapping:**
   * macOS extended attributes (`xattr`) like quarantine tags or file flags are mapped natively to NTFS Alternate Data Streams (`filename:streamname`) instead of generating `._filename` (AppleDouble) sidecar files.
3. **Synchronous Journal Flush:**
   * Disk buffer flushes are forced upon completion of critical write bursts to ensure that the NTFS transaction log is in an active, recoverable state, even if the device is unexpectedly disconnected.

### 4.4. Component 4: Autonomous Daemon (`kty-ntfsd`) & CLI (`kty-ntfs`)
* **`kty-ntfsd` (Background Daemon):**
  * Registers with `DiskArbitration.framework` using `DARegisterDiskAppearedCallback`.
  * Matches NTFS partition GUIDs (`EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`).
  * Intercepts and claims the device before macOS attaches its default read-only kernel driver.
  * Automatically coordinates with `kty-ntfs-fs.appex` to mount the drive read/write under `/Volumes/<DriveName>`.
* **`kty-ntfs` (CLI Tool):**
  * Provides granular commands for programmatic and manual control:
    * `kty-ntfs list`: Enumerate connected NTFS devices and their current claim/mount state.
    * `kty-ntfs mount <device> [options]`: Explicitly mount a partition with specific forensic flags.
    * `kty-ntfs unmount <mountpoint>`: Safely flush buffers, clear the dirty bit, and detach.
    * `kty-ntfs status`: Inspect daemon health, active mounts, and transaction statistics.

---

## 5. Mount & Unmount Operational Flow

```
[ NTFS Device Plugged In ]
           │
           ▼
[ DiskArbitration Event: DAApprovalCallback ]
           │
           ├─── Is kty-ntfsd running?
           │        ├── YES: Claim device; reject default read-only mount.
           │        └── NO:  Fall back to system default.
           ▼
[ kty-ntfsd routes to kty-ntfs-fs.appex ]
           │
           ▼
[ libkty_ntfs_core validates Boot Sector & $MFT ]
           │
           ├── Is Dirty Bit Set?
           │        ├── Fixable/Clean: Proceed with mount.
           │        └── Heavily Corrupt: Mount read-only with safety warning.
           ▼
[ Mount placed at /Volumes/<Label> ]
           │
     (I/O Operations)
           │
           ├── Finder writes .DS_Store  ───► Blocked & Filtered (Cleanliness Policy)
           ├── Forensic tool writes log ───► Written to cluster + $LogFile updated
           │
           ▼
[ Unmount Request (User or CLI) ]
           │
           ▼
[ Flush all dirty clusters to media ]
           │
           ▼
[ Mark $LogFile clean & clear VOLUME_IS_DIRTY ]
           │
           ▼
[ Release DiskArbitration claim & safely detach ]
```

---

## 6. Safety & Verification Guarantees

1. **Windows Compatibility:** Every volume modified by `kty-ntfs` must mount cleanly on Windows 10/11 without triggering an automatic "Scan and fix drive" dialog.
2. **Cryptographic Integrity:** Evidence payloads written through the layer must produce identical cryptographic hashes (SHA-256 / BLAKE3) when verified on macOS and subsequently re-read on Windows.
3. **Host Security Preservation:** Zero alterations to macOS System Integrity Protection (SIP) or Secure Boot policies.
