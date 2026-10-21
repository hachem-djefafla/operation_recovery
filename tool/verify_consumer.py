"""Test an inspected Pub archive and an unrelated public-API consumer."""

import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile

from check_archive import inspect_archive


def verify(path):
    print(inspect_archive(path), flush=True)
    dart = shutil.which("dart")
    if dart is None:
        raise RuntimeError("Dart is not on PATH")
    # Workspaces are exclusively owned by this invocation and removed on exit.
    with tempfile.TemporaryDirectory(prefix="operation_recovery_consumer_") as temporary:
        root = pathlib.Path(temporary)
        package = root / "package"
        package.mkdir()
        with tarfile.open(path, "r:gz") as archive:
            for member in archive:
                target = package.joinpath(*pathlib.PurePosixPath(member.name).parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.extractfile(member).read())
        consumer = root / "consumer"
        (consumer / "bin").mkdir(parents=True)
        (consumer / "pubspec.yaml").write_text(
            "name: recovery_archive_consumer\n"
            "environment:\n  sdk: '>=3.10.0 <4.0.0'\n"
            "dependencies:\n  operation_recovery:\n    path: ../package\n",
            encoding="utf-8",
        )
        shutil.copyfile(package / "example/public_api_smoke.dart", consumer / "bin/main.dart")
        for cwd, arguments in [
            (package, ["pub", "get"]),
            (package, ["test"]),
            (package, ["run", "example/main.dart"]),
            (consumer, ["pub", "get"]),
            (consumer, ["analyze", "--fatal-infos"]),
            (consumer, ["run", "bin/main.dart"]),
        ]:
            subprocess.run([dart, *arguments], cwd=cwd, check=True, timeout=300)
    print("Extracted package and independent consumer passed", flush=True)


if __name__ == "__main__":
    try:
        verify(pathlib.Path(sys.argv[1]).resolve())
    except (IndexError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Consumer validation failed: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(1)
