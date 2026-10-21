"""Audit Git candidates or actual staged blobs, without printing secret values."""

import pathlib
import subprocess
import sys

from check_archive import BLOCKED_PARTS, BLOCKED_SUFFIXES, SECRET_PATTERNS, is_internal_document

ROOT_FILES = {
    ".gitattributes", ".gitignore", ".pubignore", "README.md", "CHANGELOG.md",
    "CONTRIBUTING.md", "LICENSE", "pubspec.yaml", "analysis_options.yaml",
    "dartdoc_options.yaml",
}
ROOT_DIRECTORIES = {".github", "doc", "example", "lib", "test", "tool"}


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments])


def repository_files(root, staged=False):
    root = pathlib.Path(root).resolve()
    actual = pathlib.Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if actual != root:
        raise ValueError("Expected the package itself to be the Git root")
    arguments = ["ls-files", "-z", "--cached"]
    if not staged:
        arguments += ["--others", "--exclude-standard"]
    return sorted(set(git(root, *arguments).decode("utf-8").split("\0")) - {""})


def inspect_file(name, content):
    if is_internal_document(name):
        raise ValueError(f"Internal engineering document in Git: {name}")
    path = pathlib.PurePosixPath(name)
    if (path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name
            or not path.parts):
        raise ValueError("Unsafe Git path")
    if path.parts[0] not in ROOT_DIRECTORIES and name not in ROOT_FILES:
        raise ValueError(f"Unexpected package-root entry: {name}")
    if name.lower().startswith("doc/api/"):
        raise ValueError(f"Generated API documentation in Git candidates: {name}")
    if any(part in BLOCKED_PARTS - {".github"} for part in path.parts):
        raise ValueError(f"Generated/local file in Git candidates: {name}")
    if (name.lower().endswith(BLOCKED_SUFFIXES) or
            path.name.lower().startswith(".env") or
            path.suffix.lower() in {".pem", ".key", ".p12", ".pfx"} or
            path.name.lower() in {"credentials.json", "token.json", "id_rsa", "id_ed25519"}):
        raise ValueError(f"Forbidden Git artifact: {name}")
    if name.endswith("pubspec.lock") and name != "example/sqlite_recovery/pubspec.lock":
        raise ValueError(f"Unexpected lockfile: {name}")
    if b"\0" in content or any(pattern.search(content) for pattern in SECRET_PATTERNS):
        raise ValueError(f"Binary or possible credential in Git file: {name}")


def audit(root, staged=False):
    root = pathlib.Path(root).resolve()
    files = repository_files(root, staged)
    for name in files:
        source = root / name
        if source.is_symlink() or not source.resolve().is_relative_to(root):
            raise ValueError(f"Unexpected symlink or external path: {name}")
        content = git(root, "show", f":{name}") if staged else source.read_bytes()
        inspect_file(name, content)
    if "example/sqlite_recovery/pubspec.lock" not in files:
        raise ValueError("The SQLite example's real lockfile is missing")
    return files


if __name__ == "__main__":
    try:
        files = audit(pathlib.Path(__file__).resolve().parents[1], "--staged" in sys.argv)
        print(f"Audited {len(files)} {'staged blobs' if '--staged' in sys.argv else 'Git candidates'}")
        print("\n".join(files))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Git audit failed: {error}", file=sys.stderr)
        sys.exit(1)
