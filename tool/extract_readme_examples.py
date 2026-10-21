"""Make every README Dart block executable for documentation verification."""

import pathlib
import re
import shutil

root = pathlib.Path(__file__).resolve().parents[1]
blocks = re.findall(r"```dart\n(.*?)```", (root / "README.md").read_text(encoding="utf-8"), re.S)
if len(blocks) != 3:
    raise ValueError("Review documentation verification when README Dart blocks change")
domain, workflow, storage = blocks
if ("OperationRecord.prepared" not in domain or "Future<void> main()" not in workflow
        or "await store.createIfAbsent" not in storage):
    raise ValueError("Unexpected README examples")
output = root / "build/readme-check"
output.mkdir(parents=True, exist_ok=True)
(output / "main.dart").write_text(workflow, encoding="utf-8")
(output / "fragments.dart").write_text(
    "import 'package:operation_recovery/operation_recovery.dart';\n"
    "Future<void> main() async {\n" + domain + storage + "\n}\n", encoding="utf-8")
shutil.copyfile(root / "example/simulated_backend.dart", output / "simulated_backend.dart")
print("Prepared all three README Dart blocks for execution")
