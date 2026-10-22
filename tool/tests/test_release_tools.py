"""Negative tests for release gates; no native library or service is involved."""

import importlib.util
import io
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    path = pathlib.Path(__file__).resolve().parents[1] / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load("check_coverage")
archive = load("check_archive")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
repository = load("audit_repository")
release = load("prepare_release")
documentation = load("check_documentation")


class DocumentationTests(unittest.TestCase):
    def test_public_relative_external_and_fragment_links(self):
        docs = {"README.md": "[storage](doc/storage_contract.md#reads) [web](https://example.com) [here](#local)"}
        self.assertEqual(documentation.validate_links(docs, {"README.md", "doc/storage_contract.md"}), 1)

    def test_local_ignored_file_cannot_satisfy_public_link(self):
        for directory in ["doc", "docs"]:
            docs = {"README.md": f"[internal]({directory}/final_release_readiness_report.md)"}
            with self.subTest(directory=directory), self.assertRaises(ValueError):
                documentation.validate_links(docs, {"README.md"})

    def test_repository_escape_rejected(self):
        with self.assertRaises(ValueError):
            documentation.validate_links({"README.md": "[outside](../other/README.md)"}, {"README.md"})

    def test_adr_and_parent_directory_links_remain_public(self):
        docs = {"doc/adr/README.md": "[contract](../storage_contract.md) [examples](../../example/)"}
        self.assertEqual(documentation.validate_links(docs, {"doc/storage_contract.md", "example/main.dart"}), 2)


class ReleasePreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.source = self.root / "pubspec.yaml"
        self.source.write_text("name: operation_recovery\nversion: 0.1.1\npublish_to: none\n", encoding="utf-8")

    def test_only_disposable_copy_enables_publication(self):
        original = self.source.read_bytes()
        with patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"):
            stage, package = release.prepare(self.root)
        self.addCleanup(shutil.rmtree, stage)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertNotIn("publish_to", (package / "pubspec.yaml").read_text())
        self.assertIn("version: 0.1.1", (package / "pubspec.yaml").read_text())
        self.assertFalse(stage.is_relative_to(self.root))

    def test_staging_escapes_ignored_repository_ancestors(self):
        (self.root / ".git").mkdir()
        (self.root / ".pubignore").write_text("build/\n", encoding="utf-8")
        with patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"):
            stage, package = release.prepare(self.root)
        self.addCleanup(shutil.rmtree, stage)
        self.assertFalse(package.is_relative_to(self.root))
        self.assertFalse(any((parent / ".git").exists() for parent in package.parents))
        self.assertTrue((package / "pubspec.yaml").is_file())

    def test_temporary_directory_inside_repository_is_rejected(self):
        temporary_root = self.root / "build"
        temporary_root.mkdir()
        with patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"), patch.object(release.tempfile, "gettempdir", return_value=str(temporary_root)):
            with self.assertRaisesRegex(ValueError, "outside Git repositories"):
                release.prepare(self.root)
        self.assertEqual(list(temporary_root.iterdir()), [])

    def test_temporary_directory_in_another_git_worktree_is_rejected(self):
        (self.root / ".git").write_text("gitdir: elsewhere", encoding="utf-8")
        temporary_root = self.root / "temporary"
        temporary_root.mkdir()
        source_root = self.root / "source"
        source_root.mkdir()
        shutil.copyfile(self.source, source_root / "pubspec.yaml")
        with patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"), patch.object(release.tempfile, "gettempdir", return_value=str(temporary_root)):
            with self.assertRaisesRegex(ValueError, "outside Git repositories"):
                release.prepare(source_root)

    def test_failed_execution_keeps_logs_and_guard_but_removes_workspace(self):
        original = self.source.read_bytes()
        workspace = []

        def fail(command, **kwargs):
            workspace.append(pathlib.Path(kwargs["cwd"]).parent)
            kwargs["stdout"].write("injected dependency resolution failure\n")
            raise subprocess.CalledProcessError(1, command)

        with patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"), patch.object(release.shutil, "which", return_value="dart"), patch.object(release.subprocess, "run", side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                release.run(self.root)
        self.assertFalse(workspace[0].exists())
        evidence = list((self.root / "build").glob("release-stage-*"))
        self.assertEqual(len(evidence), 1)
        self.assertIn("injected", (evidence[0] / "resolution.log").read_text())
        self.assertTrue((evidence[0] / "source-manifest.json").is_file())
        self.assertFalse((evidence[0] / "package").exists())
        self.assertEqual(self.source.read_bytes(), original)

    def test_success_keeps_archive_and_consumer_evidence_outside_package(self):
        original = self.source.read_bytes()
        commands = []

        def execute(command, **kwargs):
            commands.append(command)
            kwargs["stdout"].write("simulated command completion\n")
            for argument in command:
                if argument.startswith("--to-archive="):
                    pathlib.Path(argument.split("=", 1)[1]).write_bytes(b"unit-test archive placeholder")

        with patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"), patch.object(release.shutil, "which", return_value="dart"), patch.object(release.subprocess, "run", side_effect=execute), patch.object(release, "inspect_archive", return_value="unit-test inspection"):
            release.run(self.root)
        evidence = next((self.root / "build").glob("release-stage-*"))
        self.assertEqual({item.name for item in evidence.iterdir()}, {
            "resolution.log", "dry-run.log", "archive.log", "consumer.log",
            "source-manifest.json", "operation_recovery.tar.gz", "archive-inspection.txt",
        })
        self.assertEqual(len(commands), 4)
        self.assertEqual(commands[1][1:], ["pub", "publish", "--dry-run"])
        self.assertTrue(commands[3][1].endswith("verify_consumer.py"))
        self.assertFalse(pathlib.Path(commands[3][2]).parent.exists())
        self.assertEqual(self.source.read_bytes(), original)

    def test_missing_private_guard_fails_before_copying(self):
        self.source.write_text("version: 0.1.1\n", encoding="utf-8")
        with patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"):
            with self.assertRaises(ValueError):
                release.prepare(self.root)

    def test_wrong_release_version_fails(self):
        for version in ["0.1.0", "0.2.0"]:
            self.source.write_text(f"version: {version}\npublish_to: none\n", encoding="utf-8")
            with self.subTest(version=version), patch.object(release, "audit", return_value=["pubspec.yaml"]), patch.object(release, "validate_documentation"):
                with self.assertRaises(ValueError):
                    release.prepare(self.root)

    def test_git_audit_rejects_artifacts_and_neighbors(self):
        for name in ["neighbor/pubspec.yaml", "example/build/worker", "example/recovery.db",
                     "docs/.env", "example/credentials.json", "docs/milestones_1_2_report.md",
                     "docs/final_release_readiness_report.md", "docs/release_checklist.md",
                     "docs/release_readiness_checklist.md", "doc/milestone_5_report.md",
                     "doc/final_release_readiness_report.md", "doc/release_checklist.md",
                     "docs/architecture.md", "doc/api/index.html"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                repository.inspect_file(name, b"not for publication")

    def test_git_audit_allows_workflows_and_real_example_lock(self):
        repository.inspect_file(".github/workflows/quality.yml", b"permissions: read")
        repository.inspect_file("example/sqlite_recovery/pubspec.lock", b"packages: {}")

    def test_git_audit_allows_public_doc_layout(self):
        repository.inspect_file("doc/architecture.md", b"Public architecture")
        repository.inspect_file("doc/adr/README.md", b"Public decisions")


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        (self.root / "lib").mkdir()
        (self.root / "lib/safety.dart").write_text("void run() {}", encoding="utf-8")

    def report(self, covered):
        return "SF:lib/safety.dart\n" + "\n".join(
            f"DA:{line},{int(line <= covered)}" for line in range(1, 11)
        ) + "\nend_of_record\n"

    def test_exact_threshold(self):
        self.assertIn("90.00%", coverage.check_coverage(self.report(9), self.root))

    def test_under_threshold_fails(self):
        with self.assertRaises(ValueError):
            coverage.check_coverage(self.report(8), self.root)

    def test_omitted_core_file_fails(self):
        (self.root / "lib/new_safety.dart").write_text("void run() {}", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "omitted"):
            coverage.check_coverage(self.report(10), self.root)

    def test_empty_evidence_fails(self):
        with self.assertRaises(ValueError):
            coverage.check_coverage("", self.root)

    def test_external_and_traversal_sources_fail(self):
        for name in ["../other.dart", "test/test.dart", "lib/../test.dart"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                coverage.check_coverage(f"SF:{name}\nDA:1,1\nend_of_record", self.root)

    def test_invalid_and_incomplete_records_fail(self):
        for text in ["DA:1,1", "SF:lib/safety.dart\nDA:1,1",
                     "SF:lib/safety.dart\nDA:1,-1\nend_of_record"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                coverage.check_coverage(text, self.root)

    def test_duplicate_lines_do_not_inflate_coverage(self):
        text = self.report(8).replace("end_of_record", "DA:1,999\nend_of_record")
        with self.assertRaises(ValueError):
            coverage.check_coverage(text, self.root)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name) / "candidate.tar.gz"

    def make_archive(self, extras=(), omit=()):
        with tarfile.open(self.path, "w:gz") as output:
            for name in sorted(archive.REQUIRED - set(omit)):
                content = b"public package source"
                info = tarfile.TarInfo(name)
                info.size = len(content)
                output.addfile(info, io.BytesIO(content))
            for name, content, kind in extras:
                info = tarfile.TarInfo(name)
                info.type = kind
                info.size = len(content)
                output.addfile(info, io.BytesIO(content))

    def test_valid_archive(self):
        self.make_archive([("doc/architecture.md", b"Public architecture", tarfile.REGTYPE),
                           ("doc/adr/README.md", b"Public decisions", tarfile.REGTYPE)])
        self.assertIn("SHA-256", archive.inspect_archive(self.path))

    def test_missing_public_entrypoint(self):
        self.make_archive(omit=["lib/operation_recovery.dart"])
        with self.assertRaisesRegex(ValueError, "required"):
            archive.inspect_archive(self.path)

    def test_artifacts_rejected(self):
        for name in [".dart_tool/cache", "example/build/worker", "demo.db-wal",
                     "example/sqlite_recovery/pubspec.lock",
                     "lib/native.dll", ".env", "credentials.json", "doc/api/index.html",
                     "docs/milestone_5_report.md", "docs/final_release_readiness_report.md",
                     "docs/release_checklist.md", "docs/release_readiness_checklist.md",
                     "doc/milestone_5_report.md", "doc/final_release_readiness_report.md",
                     "doc/release_checklist.md", "doc/release_readiness_checklist.md",
                     "docs/architecture.md"]:
            with self.subTest(name=name):
                self.make_archive([(name, b"artifact", tarfile.REGTYPE)])
                with self.assertRaises(ValueError):
                    archive.inspect_archive(self.path)

    def test_even_an_empty_legacy_docs_directory_is_rejected(self):
        self.make_archive([("docs/", b"", tarfile.DIRTYPE)])
        with self.assertRaisesRegex(ValueError, "Legacy docs/"):
            archive.inspect_archive(self.path)

    def test_traversal_links_and_duplicates_rejected(self):
        for name, kind in [("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                           ("link", tarfile.SYMTYPE), ("LICENSE", tarfile.REGTYPE)]:
            with self.subTest(name=name):
                self.make_archive([(name, b"", kind)])
                with self.assertRaises(ValueError):
                    archive.inspect_archive(self.path)

    def test_credentials_rejected_without_echo(self):
        secret = b"AK" + b"IA" + b"0123456789ABCDEF"
        self.make_archive([("example/settings.txt", secret, tarfile.REGTYPE)])
        with self.assertRaises(ValueError) as caught:
            archive.inspect_archive(self.path)
        self.assertNotIn(secret.decode(), str(caught.exception))

    def test_binary_disguised_as_source_rejected(self):
        self.make_archive([("example/hidden.dart", b"\x7fELF\x00native", tarfile.REGTYPE)])
        with self.assertRaises(ValueError):
            archive.inspect_archive(self.path)


if __name__ == "__main__":
    unittest.main()
