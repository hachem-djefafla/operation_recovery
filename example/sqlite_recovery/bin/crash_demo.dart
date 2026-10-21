import 'dart:convert';
import 'dart:io';

import '../tool/support/crash_harness.dart';

Future<void> main(List<String> arguments) async {
  final scenarioArgument = arguments.where(
    (value) => value.startsWith('--scenario='),
  );
  final scenario = scenarioArgument.isEmpty
      ? 'lost-response'
      : scenarioArgument.single.substring('--scenario='.length);
  try {
    final report = await runCrashScenario(scenario, log: stdout.writeln);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(
      'Verified application-process recovery; no power-loss or distributed-ownership guarantee.',
    );
  } catch (error) {
    stderr.writeln('$error');
    exitCode = 1;
  }
}
