# Windows 11 Cross-Platform Validation Runbook

This guide describes how to validate NTFS storage volumes, disk images, and evidence bundles created by **`kty-ntfs`** on native **Windows 11** and **Windows 10**.

---

## Validation Objectives

1. **Zero Auto-Repair / "Scan and Fix" Warnings:**  
   Assert that when attached to Windows, the operating system mounts the media cleanly without prompting:  
   *"There is a problem with this drive. Scan the drive now and fix it."*  
   (`fsutil dirty query` reports `Volume is NOT dirty`).

2. **0 Errors via Windows `chkdsk`:**  
   Execute `chkdsk /f` against the volume to verify:
   - 0 bad file records
   - 0 orphan cluster chains
   - 0 index corruptions (`$I30` B-tree index is consistent)
   - 0 MFT bitmap inconsistencies

3. **Bit-for-Bit Cryptographic Parity:**  
   Compare all files against the generated `manifest.json` and `checksums.sha256` to assert 100% payload integrity.

4. **Alternate Data Stream (ADS) Interoperability:**  
   Verify that macOS extended attributes written by `kty-ntfs` as Alternate Data Streams (such as `kty.integrity.sha256` and `kty.integrity.blake3`) are natively accessible in Windows PowerShell via `Get-Content -Stream`.

---

## Method A: Virtual Disk Image Validation (Fastest)

### 1. On macOS: Generate the Forensic Bundle
Run the bundle generator on macOS:
```bash
make generate-bundle
```
This produces:
- `build/kty_test_evidence.img` (32 MB NTFS test disk image)
- `build/manifest.json` (Structured checksum manifest)
- `build/checksums.sha256` (GNU/BSD sha256sum manifest)

### 2. Copy Files to Windows
Copy `build/kty_test_evidence.img`, `build/manifest.json`, and `scripts/` to your Windows 10/11 system (or a shared folder / network mount).

### 3. Run Automated Validation in PowerShell
Open PowerShell as **Administrator** and run:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-windows.ps1 -ImagePath .\build\kty_test_evidence.img -ManifestPath .\build\manifest.json
```
Or run the batch wrapper:
```cmd
scripts\verify-windows.bat
```

The script will automatically:
1. Mount the raw `.img` file via `Mount-DiskImage`.
2. Inspect the volume dirty bit using `fsutil dirty query`.
3. Audit filesystem integrity using `chkdsk`.
4. Validate SHA-256 and BLAKE3 checksums for all files.
5. Query and verify all Alternate Data Streams.
6. Dismount cleanly.

---

## Method B: Physical USB Drive Validation

### 1. On macOS: Format or Write to USB Drive
Plug your USB drive into your Mac and note its BSD node (e.g. `/dev/disk4s1`).

Generate the cross-platform forensic test bundle:
```bash
make generate-bundle
```

Option A: Write the generated evidence image directly to the physical USB partition:
```bash
sudo dd if=build/kty_test_evidence.img of=/dev/rdisk4s1 bs=1m status=progress
```

Option B: Mount the target disk via `kty-ntfs` companion CLI and copy forensic files:
```bash
./build/bin/kty-ntfs mount disk4s1
# Copy evidence files or case folders to /Volumes/disk4s1 ...
./build/bin/kty-ntfs unmount disk4s1
```

### 2. Plug the USB Drive into Windows 11
Note the assigned drive letter (e.g. `E:`).

Assert that Windows mounts the drive **instantly without any popups or warnings**.

### 3. Run the Automated Validator
In an elevated PowerShell window:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-windows.ps1 -PhysicalDriveLetter E -ManifestPath .\build\manifest.json
```

---

## Manual Verification Checklist

If executing checks manually in Windows Command Prompt:

```cmd
:: 1. Assert Volume is NOT Dirty
fsutil dirty query E:
:: Expected: "Volume - E: is NOT dirty"

:: 2. Run CHKDSK Filesystem Audit
chkdsk E: /f
:: Expected: "Windows has scanned the file system and found no problems."
:: Expected: "0 bad file records processed."
:: Expected: "0 unindexed files scanned."

:: 3. Read Alternate Data Streams in PowerShell
Get-Item E:\cases\case_001\evidence_blob.bin -Stream *
Get-Content E:\cases\case_001\evidence_blob.bin -Stream kty.integrity.sha256
Get-Content E:\cases\case_001\evidence_blob.bin -Stream kty.integrity.blake3
```
