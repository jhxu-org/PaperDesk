#!/usr/bin/env python3
"""Check the Git index, never local library contents. Pair with Gitleaks before pushing."""
from pathlib import PurePosixPath
import re
import subprocess
import sys

ALLOWED_ROOTS = {"Assets", "BrowserExtension", "Distribution", "Sources", "Tests", "scripts", "docs", ".github"}
ALLOWED_FILES = {".gitleaks.toml", ".gitignore", ".gitattributes", "Package.swift", "Package.resolved", "README.md", "LICENSE", "NOTICE", "SECURITY.md", "CHANGELOG.md"}
FORBIDDEN_SUFFIXES = {".pdf", ".sqlite", ".db", ".log", ".jsonl", ".har", ".pem", ".key", ".p12", ".pfx", ".dmg", ".zip", ".gz"}
FORBIDDEN_PARTS = {".build", "dist", ".DS_Store", "node_modules", "BrowserInbox", "Documents", "PaperDesk Library", "__pycache__"}
IDENTITY = re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/|/var/folders/[a-z0-9/]+")


def main():
    index = subprocess.check_output(["git", "ls-files", "--stage", "-z"]).split(b"\0")
    findings = []
    count = 0
    for entry in filter(None, index):
        metadata, raw_path = entry.split(b"\t", 1)
        mode, oid, stage = metadata.split()
        path = raw_path.decode("utf-8")
        p = PurePosixPath(path)
        count += 1
        if p.parts[0] not in ALLOWED_ROOTS and path not in ALLOWED_FILES:
            findings.append((path, "unexpected publication path"))
        if (set(p.parts) & FORBIDDEN_PARTS or p.suffix.lower() in FORBIDDEN_SUFFIXES
                or any(part.startswith(".env") or ".sqlite" in part for part in p.parts)):
            findings.append((path, "private or generated artifact"))
        if mode not in (b"100644", b"100755") or stage != b"0":
            findings.append((path, "symlink, submodule or unresolved index entry"))
            continue
        data = subprocess.check_output(["git", "cat-file", "blob", oid.decode()])
        if len(data) > 8 * 1024 * 1024:
            findings.append((path, "unexpected large asset"))
        if IDENTITY.search(data):
            findings.append((path, "absolute personal filesystem path"))
    if not count:
        findings.append(("index", "no staged or tracked files to inspect"))
    for path, reason in findings:
        print(f"FAIL {path}: {reason}")  # Never print a matched value or file contents.
    print(f"Checked {count} Git index files; {len(findings)} publication guard findings.")
    return bool(findings)


if __name__ == "__main__":
    sys.exit(main())
