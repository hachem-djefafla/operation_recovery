import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';

final demoIdentity = OperationIdentity(
  id: 'crash-demo-operation',
  scope: 'demo-account',
  type: 'transfer',
  idempotencyKey: 'crash-demo-key',
  requestFingerprint: 'sha256:demo-fingerprint',
);

final demoEpoch = DateTime.utc(2026, 10, 20, 10);

final class DemoClock implements Clock {
  DemoClock(this.value);
  DateTime value;
  @override
  DateTime now() => value;
}

Map<String, Object?> identityJson(OperationIdentity identity) => {
  'id': identity.id,
  'scope': identity.scope,
  'type': identity.type,
  'key': identity.idempotencyKey,
  'fingerprint': identity.requestFingerprint,
};

OperationIdentity identityFromJson(Map<String, Object?> json) =>
    OperationIdentity(
      id: json['id']! as String,
      scope: json['scope']! as String,
      type: json['type']! as String,
      idempotencyKey: json['key']! as String,
      requestFingerprint: json['fingerprint']! as String,
    );

Map<String, Object?> snapshot(OperationRecord? record) => record == null
    ? {}
    : {
        'identity': identityJson(record.identity),
        'state': record.state.name,
        'version': record.version,
        'createdAt': record.createdAt.toIso8601String(),
        'updatedAt': record.updatedAt.toIso8601String(),
        'cycle': record.recovery.cycleAttempts,
        'total': record.recovery.totalAttempts,
        'last': record.recovery.lastAttemptAt?.toIso8601String(),
        'next': record.recovery.nextCheckAt?.toIso8601String(),
        'lookupFailure': switch (record.lastObservation) {
          LookupUnavailable(:final reason) => reason.name,
          _ => null,
        },
      };

Map<String, Object?> jsonObject(String line) =>
    Map<String, Object?>.from(jsonDecode(line) as Map<String, dynamic>);

final class WorkerChannel {
  WorkerChannel({Stream<List<int>>? input, IOSink? output})
    : _lines = StreamIterator(
        (input ?? stdin)
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      ),
      _output = output ?? stdout;

  final StreamIterator<String> _lines;
  final IOSink _output;
  Future<void> _writes = Future<void>.value();
  Future<void>? _closing;

  Future<Map<String, Object?>> next() async {
    if (!await _lines.moveNext()) throw StateError('Control channel closed');
    return jsonObject(_lines.current);
  }

  Future<void> emit(Map<String, Object?> message) {
    if (_closing != null) return Future.error(StateError('Channel is closing'));
    final line = jsonEncode(message);
    // flush binds IOSink until its future completes. Queue the entire write and
    // flush, including emissions from independent HTTP and control callbacks.
    return _writes = _writes.then((_) async {
      _output.writeln(line);
      await _output.flush();
    });
  }

  Future<void> checkpoint(String name, int sequence) async {
    await emit({'kind': 'checkpoint', 'name': name, 'seq': sequence});
    final command = await next();
    if (command['action'] != 'continue') {
      throw StateError('Checkpoint requires continue or forced process death');
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await _writes;
    } finally {
      await _lines.cancel();
    }
  }
}
