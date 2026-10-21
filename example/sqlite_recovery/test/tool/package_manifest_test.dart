import 'dart:io';

import 'package:test/test.dart';

import '../../tool/support/package_manifest.dart';

void main() {
  for (final absolute in [false, true]) {
    for (final trailingSlash in [false, true]) {
      test('reads the package manifest with '
          '${absolute ? 'absolute' : 'relative'} rootUri, '
          'trailing slash: $trailingSlash', () {
        final directory = Directory.systemTemp.createTempSync(
          'package manifest # ',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final cache = Directory.fromUri(directory.uri.resolve('cache/'))
          ..createSync();
        final package = Directory.fromUri(cache.uri.resolve('sqlite3-3.7.1/'))
          ..createSync();
        File.fromUri(
          cache.uri.resolve('pubspec.yaml'),
        ).writeAsStringSync('wrong parent manifest');
        final expected = File.fromUri(package.uri.resolve('pubspec.yaml'))
          ..writeAsStringSync('name: sqlite3\nversion: 3.7.1\n');
        final config = directory.uri.resolve('.dart_tool/package_config.json');
        var rootUri = absolute
            ? package.uri.toString()
            : '../cache/sqlite3-3.7.1/';
        if (!trailingSlash) {
          rootUri = rootUri.substring(0, rootUri.length - 1);
        }

        final manifest = resolvePackageManifest(config, rootUri);

        expect(manifest.uri, expected.uri);
        expect(manifest.readAsStringSync(), 'name: sqlite3\nversion: 3.7.1\n');
      });
    }
  }
}
