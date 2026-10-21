import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'package:operation_recovery_sqlite_example/sqlite_operation_store.dart';

import 'support/package_manifest.dart';

/// Records actual Dart FFI loading and package resolution, independent of the CLI.
void main() {
  final configFile = File('.dart_tool/package_config.json').absolute;
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final packages = config['packages']! as List<dynamic>;
  final dependency = packages.cast<Map<String, dynamic>>().singleWhere(
    (package) => package['name'] == 'sqlite3',
  );
  final manifest = resolvePackageManifest(
    configFile.uri,
    dependency['rootUri']! as String,
  ).readAsStringSync();
  if (!RegExp(r'^version:\s*3\.7\.1\s*$', multiLine: true).hasMatch(manifest)) {
    throw StateError('The resolved sqlite3 package is not the approved 3.7.1');
  }
  final directory = Directory.systemTemp.createTempSync(
    'operation_recovery_probe_',
  );
  final path = directory.uri.resolve('probe.sqlite').toFilePath();
  try {
    final store = SqliteOperationStore.create(path);
    late final Map<String, Object?> configuration;
    try {
      configuration = store.configuration;
    } finally {
      store.close();
    }
    final database = sqlite3.open(path, mode: OpenMode.readWrite);
    late final Object? sourceId;
    try {
      sourceId = database
          .select('SELECT sqlite_source_id()')
          .single
          .values
          .single;
    } finally {
      database.close();
    }
    final evidence = {
      'dart': Platform.version,
      'os': Platform.operatingSystem,
      'sqlite3Package': '3.7.1',
      'configuration': configuration,
      'sqliteSourceId': sourceId,
      'mechanism':
          'sqlite3 build hooks and native assets; no system CLI invoked',
    };
    Directory('build').createSync(recursive: true);
    final json = const JsonEncoder.withIndent('  ').convert(evidence);
    File('build/native-evidence.json').writeAsStringSync('$json\n');
    stdout.writeln(json);
  } finally {
    // This exact directory was exclusively created above and is never supplied
    // by input. Do not generalize this cleanup to arbitrary database paths.
    if (directory.resolveSymbolicLinksSync() != directory.absolute.path) {
      throw StateError('Probe directory unexpectedly changed');
    }
    directory.deleteSync(recursive: true);
  }
}
