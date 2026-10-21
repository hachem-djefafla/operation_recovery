"""Inspect the actual Pub-generated tar.gz without extracting or executing it."""

import hashlib
import pathlib
import re
import sys
import tarfile

REQUIRED = {"pubspec.yaml", "README.md", "CHANGELOG.md", "LICENSE", "lib/operation_recovery.dart"}
BLOCKED_PARTS = {
    ".git", ".github", ".dart_tool", ".codex", ".agents", ".aws", "build",
    "coverage", "__pycache__", "node_modules", ".venv",
}
BLOCKED_NAMES = {".packages", "pubspec.lock", "credentials.json", "token.json", "id_rsa", "id_ed25519"}
BLOCKED_SUFFIXES = (
    ".db", ".sqlite", ".sqlite3", "-wal", "-shm", "-journal", ".exe", ".dll",
    ".so", ".dylib", ".aot", ".snapshot", ".log", ".pyc", ".zip", ".tar.gz", ".p12", ".pfx",
)
# Detection is defense in depth; archive review remains required. Never echo matches.
SECRET_PATTERNS = [
    re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    re.compile(rb"(?:AKIA|ASIA)[A-Z0-9]{16}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{40,}"),
    re.compile(rb'"(?:access_token|refresh_token|private_key)"\s*:\s*"[^"\s]{12,}"'),
]


def is_internal_document(name):
    path = pathlib.PurePosixPath(name.lower())
    return (path.parent == pathlib.PurePosixPath("docs") and path.suffix == ".md"
            and ("report" in path.name or ("release" in path.name and "checklist" in path.name)))


def inspect_archive(path):
    files = set()
    with tarfile.open(path, "r:gz") as archive:
        for member in archive:
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            parts = pathlib.PurePosixPath(name).parts
            if not parts or ".." in parts or "\\" in name or ":" in name or name.startswith("/"):
                raise ValueError("Unsafe archive path")
            lower = name.lower()
            if is_internal_document(name):
                raise ValueError(f"Internal engineering document in archive: {name}")
            if any(part.lower() in BLOCKED_PARTS for part in parts):
                raise ValueError(f"Development artifact in archive: {name}")
            if member.isdir():
                continue
            if not member.isfile() or member.size > 4 * 1024 * 1024:
                raise ValueError(f"Unsupported link/type/size in archive: {name}")
            if name in files:
                raise ValueError("Duplicate archive entry")
            files.add(name)
            base = parts[-1].lower()
            if (base in BLOCKED_NAMES or base.startswith(".env") or
                    lower.endswith(BLOCKED_SUFFIXES) or lower.startswith("doc/api/") or
                    re.search(r"\.(?:db|sqlite|sqlite3)-", lower)):
                raise ValueError(f"Forbidden archive artifact: {name}")
            content = archive.extractfile(member).read()
            if any(pattern.search(content) for pattern in SECRET_PATTERNS):
                raise ValueError(f"Possible credential in archive: {name}")
            if b"\x00" in content:
                raise ValueError(f"Unexpected binary content in archive: {name}")
    if REQUIRED - files:
        raise ValueError("Archive missing required files: " + ", ".join(sorted(REQUIRED - files)))
    digest = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    return f"Archive inspected: {len(files)} files; SHA-256 {digest}\n" + "\n".join(sorted(files))


if __name__ == "__main__":
    try:
        print(inspect_archive(sys.argv[1]))
    except (IndexError, OSError, ValueError, tarfile.TarError) as error:
        print(f"Archive check failed: {error}", file=sys.stderr)
        sys.exit(1)
