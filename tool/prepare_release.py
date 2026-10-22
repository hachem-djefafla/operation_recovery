"""Prepare/validate a disposable publication copy; never upload or change source."""

import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

from audit_repository import audit
from check_archive import inspect_archive
from check_documentation import validate_documentation


def prepare(root):
    root = pathlib.Path(root).resolve()
    files = audit(root)
    validate_documentation(root)
    manifest = (root / "pubspec.yaml").read_text(encoding="utf-8")
    if not re.search(r"^version: 0\.1\.1\s*$", manifest, re.MULTILINE):
        raise ValueError("Expected prepared release version 0.1.1")
    manifest, count = re.subn(r"^publish_to: none\r?\n", "", manifest, flags=re.MULTILINE)
    if count != 1:
        raise ValueError("Source must retain exactly one publish_to: none guard")
    temporary_root = pathlib.Path(tempfile.gettempdir()).resolve()
    if temporary_root.is_relative_to(root) or any(
        (parent / ".git").exists() for parent in (temporary_root, *temporary_root.parents)
    ):
        raise ValueError("Release staging requires a system temporary directory outside Git repositories; check TMP/TEMP")
    stage = pathlib.Path(tempfile.mkdtemp(prefix="operation_recovery_release_", dir=temporary_root))
    package = stage / "package"
    try:
        for name in files:
            target = package / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / name, target)
        (package / "pubspec.yaml").write_text(manifest, encoding="utf-8", newline="\n")
        (stage / "source-manifest.json").write_text(json.dumps(files, indent=2), encoding="utf-8")
    except BaseException:
        shutil.rmtree(stage)
        raise
    return stage, package


def run(root, prepare_only=False):
    original = (root / "pubspec.yaml").read_bytes()
    stage, package = prepare(root)
    print(f"Disposable release copy: {package}", flush=True)
    if prepare_only:
        print(f"Inspection only: temporary copy retained at {stage}", flush=True)
        return
    build = root / "build"
    build.mkdir(exist_ok=True)
    evidence = pathlib.Path(tempfile.mkdtemp(prefix="release-stage-", dir=build))
    print(f"Release evidence (also retained on failure): {evidence}", flush=True)
    try:
        dart = shutil.which("dart")
        if dart is None:
            raise RuntimeError("Dart is not on PATH")
        for name, arguments in [
            ("resolution", ["pub", "get"]),
            ("dry-run", ["pub", "publish", "--dry-run"]),
            ("archive", ["pub", "publish", "--to-archive=" + str(stage / "operation_recovery.tar.gz")]),
        ]:
            with (stage / f"{name}.log").open("w", encoding="utf-8") as output:
                subprocess.run([dart, *arguments], cwd=package, stdout=output,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
        result = inspect_archive(stage / "operation_recovery.tar.gz")
        (stage / "archive-inspection.txt").write_text(result + "\n", encoding="utf-8")
        print(result, flush=True)
        with (stage / "consumer.log").open("w", encoding="utf-8") as output:
            subprocess.run([sys.executable, str(root / "tool/verify_consumer.py"),
                            str(stage / "operation_recovery.tar.gz")], stdout=output,
                           stderr=subprocess.STDOUT, check=True, timeout=900)
        print("Extracted package and independent consumer passed", flush=True)
    finally:
        try:
            # Keep only evidence here. Pub never packages from the ignored build/.
            for item in stage.iterdir():
                if item.is_file():
                    shutil.copyfile(item, evidence / item.name)
        finally:
            # stage was exclusively allocated above, never supplied by input.
            shutil.rmtree(stage)
            if (root / "pubspec.yaml").read_bytes() != original:
                raise RuntimeError("Source manifest changed during release validation")


if __name__ == "__main__":
    try:
        run(pathlib.Path(__file__).resolve().parents[1], "--prepare-only" in sys.argv)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
