"""Validate public Markdown links against Git files, never ignored local files."""

import pathlib
import posixpath
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

from audit_repository import git, repository_files


def validate_links(documents, available):
    count = 0
    for name, text in documents.items():
        for raw in re.findall(r"\]\(([^)]+)\)", text):
            target = urlsplit(raw.strip().strip("<>"))
            if target.scheme or target.netloc or not target.path:
                continue
            path = posixpath.normpath(posixpath.join(posixpath.dirname(name), unquote(target.path)))
            if path.startswith("../") or path.startswith("/"):
                raise ValueError(f"Public link escapes repository: {name} -> {raw}")
            if path not in available and not any(item.startswith(path.rstrip("/") + "/") for item in available):
                raise ValueError(f"Public link targets an excluded/missing file: {name} -> {raw}")
            count += 1
    return count


def validate_documentation(root, staged=False):
    root = pathlib.Path(root).resolve()
    files = set(repository_files(root, staged))
    documents = {
        name: (git(root, "show", f":{name}").decode("utf-8") if staged
               else (root / name).read_text(encoding="utf-8"))
        for name in files if name.endswith(".md")
    }
    count = validate_links(documents, files)
    return f"Validated {count} relative public links across {len(documents)} Markdown files"


if __name__ == "__main__":
    try:
        print(validate_documentation(pathlib.Path(__file__).resolve().parents[1], "--staged" in sys.argv))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Documentation check failed: {error}", file=sys.stderr)
        sys.exit(1)
