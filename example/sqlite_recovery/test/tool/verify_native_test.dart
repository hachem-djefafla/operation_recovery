import 'dart:io';

import 'package:test/test.dart';

import '../../tool/verify_native.dart' as probe;

void main() {
  late Directory parent;
  late Directory temporaryRoot;
  late File sentinel;

  setUp(() {
    parent = Directory.systemTemp.createTempSync('native_probe_test_');
    addTearDown(() => parent.deleteSync(recursive: true));
    // The same directory has different absolute and canonical spellings.
    temporaryRoot = Directory('${parent.path}${Platform.pathSeparator}.');
    sentinel = File.fromUri(parent.uri.resolve('keep.txt'))
      ..writeAsStringSync('outside the probe directory');
  });

  void expectOnlySentinelRemains() {
    expect(parent.listSync().map((entry) => entry.path), [sentinel.path]);
    expect(sentinel.readAsStringSync(), 'outside the probe directory');
  }

  test(
    'probe succeeds and cleans its exclusively created aliased directory',
    () {
      expect(
        temporaryRoot.resolveSymbolicLinksSync(),
        isNot(temporaryRoot.path),
      );

      IOOverrides.runZoned(
        probe.main,
        getSystemTempDirectory: () => temporaryRoot,
      );

      expectOnlySentinelRemains();
    },
  );

  test(
    'probe cleans its directory without masking an evidence-write failure',
    () {
      final failure = StateError('injected evidence-write failure');
      final systemIO = _SystemIOOverrides();

      expect(
        () => IOOverrides.runZoned(
          probe.main,
          getSystemTempDirectory: () => temporaryRoot,
          createFile: (path) {
            if (path == 'build/native-evidence.json') throw failure;
            return systemIO.createFile(path);
          },
        ),
        throwsA(same(failure)),
      );

      expectOnlySentinelRemains();
    },
  );
}

final class _SystemIOOverrides extends IOOverrides {}
