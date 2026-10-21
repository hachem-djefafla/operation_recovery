import 'dart:io';

/// Resolves a package manifest even when package_config omits the trailing slash.
File resolvePackageManifest(Uri packageConfig, String rootUri) {
  final root = Directory.fromUri(packageConfig.resolve(rootUri));
  return File.fromUri(root.uri.resolve('pubspec.yaml'));
}
