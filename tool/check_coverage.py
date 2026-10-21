"""Enforce core line coverage, rejecting empty or incomplete LCOV evidence."""

import pathlib
import re
import sys

# These libraries contain declarations/exports only, with no executable bodies.
# All executable domain, orchestration, error, and adapter code remains required.
DECLARATIONS_ONLY = {
    "lib/operation_recovery.dart",
    "lib/src/ports/clock.dart",
    "lib/src/ports/operation_handler.dart",
    "lib/src/ports/operation_store.dart",
}


def check_coverage(text, root):
    root = pathlib.Path(root).resolve()
    hits = {}
    current = None
    for raw in text.splitlines():
        if raw.startswith("SF:"):
            if current is not None:
                raise ValueError("Unterminated coverage record")
            source = raw[3:].replace("\\", "/")
            if source.startswith("package:operation_recovery/"):
                source = "lib/" + source.split("/", 1)[1]
            path = pathlib.Path(source)
            path = (root / path).resolve() if not path.is_absolute() else path.resolve()
            if not path.is_relative_to(root / "lib"):
                raise ValueError("Coverage contains a non-core source")
            current = path.relative_to(root).as_posix()
            hits.setdefault(current, {})
        elif raw.startswith("DA:"):
            if current is None:
                raise ValueError("Coverage line has no source")
            match = re.fullmatch(r"DA:([1-9][0-9]*),([0-9]+)(?:,[^,]+)?", raw)
            if match is None:
                raise ValueError("Malformed line coverage")
            line, count = map(int, match.group(1, 2))
            hits[current][line] = max(count, hits[current].get(line, 0))
        elif raw == "end_of_record":
            if current is None:
                raise ValueError("Coverage record has no source")
            current = None
    if current is not None:
        raise ValueError("Unterminated coverage record")
    expected = {
        file.relative_to(root).as_posix()
        for file in (root / "lib").rglob("*.dart")
    } - DECLARATIONS_ONLY
    if not expected:
        raise ValueError("No executable core source files found")
    missing = expected - {name for name, lines in hits.items() if lines}
    if missing:
        raise ValueError("Coverage omitted core files: " + ", ".join(sorted(missing)))
    lines = [count for values in hits.values() for count in values.values()]
    if not lines:
        raise ValueError("Empty coverage evidence")
    covered = sum(count > 0 for count in lines)
    if covered * 100 < len(lines) * 90:
        raise ValueError(f"Core coverage {covered}/{len(lines)} is below 90%")
    return f"Core line coverage: {covered}/{len(lines)} ({covered / len(lines):.2%})"


if __name__ == "__main__":
    try:
        print(check_coverage(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), "."))
    except (IndexError, OSError, ValueError) as error:
        print(f"Coverage check failed: {error}", file=sys.stderr)
        sys.exit(1)
