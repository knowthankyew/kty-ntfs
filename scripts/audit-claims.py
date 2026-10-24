#!/usr/bin/env python3
"""
audit-claims.py
Automated documentation, metadata, and architectural claims linter for kty-ntfs.
Enforces parity across Info.plist, entitlements.plist, sources, NOTICE.md, and licensing claims.
Part of the knowthankyew portfolio quality gates.
"""

from pathlib import Path
import plistlib
import re
import sys


def fail(errors: list[str], msg: str) -> None:
    errors.append(msg)


def read_text_checked(root: Path, rel_path: str, errors: list[str]) -> str | None:
    target = root / rel_path
    if not target.is_file():
        fail(errors, f"Missing required file: {rel_path}")
        return None
    try:
        return target.read_text(encoding="utf-8")
    except OSError as exc:
        fail(errors, f"Could not read {rel_path}: {exc}")
        return None


def load_plist_checked(root: Path, rel_path: str, errors: list[str]) -> dict | None:
    target = root / rel_path
    if not target.is_file():
        fail(errors, f"Missing required plist: {rel_path}")
        return None
    try:
        with target.open("rb") as f:
            data = plistlib.load(f)
        if not isinstance(data, dict):
            fail(errors, f"Plist {rel_path} root is not a dictionary")
            return None
        return data
    except Exception as exc:
        fail(errors, f"Could not parse plist {rel_path}: {exc}")
        return None


def check_version_and_metadata_parity(root: Path, errors: list[str]) -> str:
    plist = load_plist_checked(root, "src/fskit/Info.plist", errors)
    if plist is None:
        return "0.0.0"

    version = str(plist.get("CFBundleShortVersionString", ""))
    bundle_name = str(plist.get("CFBundleName", ""))
    bundle_id = str(plist.get("CFBundleIdentifier", ""))

    if not version:
        fail(errors, "CFBundleShortVersionString is empty in src/fskit/Info.plist")
    if bundle_name != "kty-ntfs-fs":
        fail(errors, f"CFBundleName in src/fskit/Info.plist expected 'kty-ntfs-fs', got '{bundle_name}'")
    if bundle_id != "com.knowthankyew.kty-ntfs.fsmodule":
        fail(errors, f"CFBundleIdentifier expected 'com.knowthankyew.kty-ntfs.fsmodule', got '{bundle_id}'")

    # ExtensionKit schema validation
    attrs = plist.get("EXAppExtensionAttributes")
    if not isinstance(attrs, dict):
        fail(errors, "src/fskit/Info.plist missing EXAppExtensionAttributes dictionary")
    else:
        ep_id = attrs.get("EXExtensionPointIdentifier")
        if ep_id != "com.apple.fskit.fsmodule":
            fail(errors, f"EXExtensionPointIdentifier expected 'com.apple.fskit.fsmodule', got '{ep_id}'")
        if attrs.get("FSShortName") != "ntfs":
            fail(errors, "FSShortName in EXAppExtensionAttributes must be 'ntfs'")
        if attrs.get("FSSupportsBlockResources") is not True:
            fail(errors, "FSSupportsBlockResources in EXAppExtensionAttributes must be true")

        media_types = attrs.get("FSMediaTypes", {})
        ntfs_guid = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
        if ntfs_guid not in media_types:
            fail(errors, f"FSMediaTypes missing NTFS partition GUID '{ntfs_guid}'")

    return version


def check_entitlements_and_notice_parity(root: Path, errors: list[str]) -> None:
    entitlements = load_plist_checked(root, "src/fskit/entitlements.plist", errors)
    if entitlements is None:
        return

    if entitlements.get("com.apple.security.app-sandbox") is not True:
        fail(errors, "src/fskit/entitlements.plist must set com.apple.security.app-sandbox to true")
    if entitlements.get("com.apple.developer.fskit.fsmodule") is not True:
        fail(errors, "src/fskit/entitlements.plist must set com.apple.developer.fskit.fsmodule to true")

    notice_text = read_text_checked(root, "NOTICE.md", errors)
    if notice_text is not None:
        for key in entitlements.keys():
            if f"`{key}`" not in notice_text:
                fail(errors, f"Entitlement `{key}` is declared in entitlements.plist but missing from NOTICE.md table")


def check_licensing_and_portfolio_claims(root: Path, errors: list[str]) -> None:
    license_text = read_text_checked(root, "LICENSE", errors)
    if license_text is not None:
        if "GNU GENERAL PUBLIC LICENSE" not in license_text:
            fail(errors, "LICENSE file does not contain 'GNU GENERAL PUBLIC LICENSE'")
        if "Version 2" not in license_text:
            fail(errors, "LICENSE file is missing GPL Version 2 declaration")

    readme_text = read_text_checked(root, "README.md", errors)
    if readme_text is not None:
        if "GPL-2.0-or-later" not in readme_text:
            fail(errors, "README.md must explicitly reference 'GPL-2.0-or-later'")
        if "MIT License" not in readme_text:
            fail(errors, "README.md must document the portfolio distinction regarding the MIT License")
        if "Process Boundary Isolation" not in readme_text:
            fail(errors, "README.md must document Process Boundary Isolation")

    notice_text = read_text_checked(root, "NOTICE.md", errors)
    if notice_text is not None:
        if "GPL-2.0-or-later" not in notice_text:
            fail(errors, "NOTICE.md must document 'GPL-2.0-or-later'")
        if "MIT License" not in notice_text:
            fail(errors, "NOTICE.md must document the portfolio MIT distinction")

    bom_text = read_text_checked(root, "bom.json", errors)
    if bom_text is not None:
        if "CycloneDX" not in bom_text:
            fail(errors, "bom.json must be a CycloneDX formatted SBOM")
        if "kty-ntfs" not in bom_text:
            fail(errors, "bom.json must declare kty-ntfs component")


FORBIDDEN_EGRESS_PATTERNS = [
    (r"\bimport\s+Network\b", "import Network"),
    (r"\bimport\s+CFNetwork\b", "import CFNetwork"),
    (r"\bimport\s+WebKit\b", "import WebKit"),
    (r"#\s*(?:import|include)\s*[<\"](?:CFNetwork|Network|WebKit)/", "#include Network/CFNetwork/WebKit"),
    (r"\bN?S?URLSession\b", "URLSession/NSURLSession"),
    (r"\bNSURLConnection\b", "NSURLConnection"),
    (r"\bNWConnection\b", "NWConnection"),
    (r"\bNWListener\b", "NWListener"),
    (r"\bsocket\s*\(", "BSD socket(...)"),
    (r"(?<!\.)\b(?:Darwin\.)?connect\s*\(", "BSD connect(...)"),
    (r"\bsockaddr_in6?\b", "sockaddr_in/sockaddr_in6"),
    (r"\bCFSocket\w*\b", "CFSocket"),
    (r"sys/socket\.h", "sys/socket.h"),
    (r"\bgetaddrinfo\s*\(", "getaddrinfo(...)"),
]


def scan_source_for_egress(content: str) -> list[str]:
    matched: list[str] = []
    for pattern, label in FORBIDDEN_EGRESS_PATTERNS:
        if re.search(pattern, content):
            matched.append(label)
    return matched


def check_zero_egress(root: Path, errors: list[str]) -> None:
    source_exts = {".c", ".h", ".m", ".swift"}
    scan_dirs = ["src", "tests"]

    for d in scan_dirs:
        dir_path = root / d
        if not dir_path.is_dir():
            continue
        for file_path in dir_path.rglob("*"):
            if file_path.suffix in source_exts and "vendor" not in file_path.parts:
                try:
                    content = file_path.read_text(encoding="utf-8")
                except Exception:
                    continue
                violations = scan_source_for_egress(content)
                if violations:
                    rel = file_path.relative_to(root)
                    fail(errors, f"Zero-egress violation in {rel}: prohibited symbols {violations}")


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors: list[str] = []

    version = check_version_and_metadata_parity(root, errors)
    check_entitlements_and_notice_parity(root, errors)
    check_licensing_and_portfolio_claims(root, errors)
    check_zero_egress(root, errors)

    print(f"=== kty-ntfs Claims & Architecture Audit (v{version}) ===")
    if errors:
        print(f"\nFAILED: {len(errors)} invariant violation(s) detected:")
        for err in errors:
            print(f"  [X] {err}")
        return 1

    print("\nAll architectural claims, licensing distinctions, entitlements, and zero-egress invariants verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
