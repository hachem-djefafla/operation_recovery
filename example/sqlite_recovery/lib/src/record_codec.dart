import 'dart:convert';

import 'package:operation_recovery/operation_recovery.dart';

/// Explicit version-one row format. These tags are independent of enum names.
const recordColumns = <String>[
  'operation_id',
  'scope',
  'operation_type',
  'idempotency_key',
  'request_fingerprint',
  'record_schema_version',
  'state',
  'record_version',
  'created_at_us',
  'updated_at_us',
  'observation_kind',
  'backend_reference',
  'rejection_code',
  'lookup_failure_reason',
  'cycle_attempts',
  'total_attempts',
  'last_attempt_at_us',
  'next_check_at_us',
];

/// SQL INTEGER columns, including optional timestamps.
const integerColumns = <String>{
  'record_schema_version',
  'record_version',
  'created_at_us',
  'updated_at_us',
  'cycle_attempts',
  'total_attempts',
  'last_attempt_at_us',
  'next_check_at_us',
};

/// Columns for which null has an explicit semantic meaning.
const nullableColumns = <String>{
  'observation_kind',
  'backend_reference',
  'rejection_code',
  'lookup_failure_reason',
  'last_attempt_at_us',
  'next_check_at_us',
};

/// Encodes all fields without defaults or ambient time.
List<Object?> encodeRecord(OperationRecord record) {
  final observed = record.lastObservation;
  final values = <Object?>[
    record.identity.id,
    record.identity.scope,
    record.identity.type,
    record.identity.idempotencyKey,
    record.identity.requestFingerprint,
    1,
    switch (record.state) {
      OperationState.prepared => 'prepared',
      OperationState.awaitingOutcome => 'awaiting_outcome',
      OperationState.needsAttention => 'needs_attention',
      OperationState.succeeded => 'succeeded',
      OperationState.rejected => 'rejected',
    },
    record.version,
    record.createdAt.microsecondsSinceEpoch,
    record.updatedAt.microsecondsSinceEpoch,
    switch (observed) {
      OperationSucceeded() => 'succeeded',
      OperationRejected() => 'rejected',
      OperationPending() => 'pending',
      OperationUnknown() => 'unknown',
      LookupUnavailable() => 'unavailable',
      null => null,
    },
    observed is OperationSucceeded ? observed.backendReference : null,
    observed is OperationRejected ? observed.code : null,
    observed is LookupUnavailable
        ? switch (observed.reason) {
            LookupFailureReason.authenticationRequired =>
              'authentication_required',
            LookupFailureReason.transportFailure => 'transport_failure',
            LookupFailureReason.serviceUnavailable => 'service_unavailable',
          }
        : null,
    record.recovery.cycleAttempts,
    record.recovery.totalAttempts,
    record.recovery.lastAttemptAt?.microsecondsSinceEpoch,
    record.recovery.nextCheckAt?.microsecondsSinceEpoch,
  ];
  for (var index = 0; index < values.length; index++) {
    final value = values[index];
    if (value is String && utf8.decode(utf8.encode(value)) != value) {
      throw InvalidOperationRecordException(
        'persistence.${recordColumns[index]}',
        'must round-trip through UTF-8 without replacement',
      );
    }
  }
  return values;
}

/// Restores only known, structurally valid rows. No corrupt row becomes prepared.
OperationRecord decodeRecord(Map<String, Object?> row) {
  Never invalid(String field) => throw InvalidOperationRecordException(
    'persistence.$field',
    'invalid or unsupported serialized value',
  );
  String text(String key) =>
      row[key] is String ? row[key]! as String : invalid(key);
  int integer(String key) => row[key] is int ? row[key]! as int : invalid(key);
  String? optionalText(String key) => row[key] == null ? null : text(key);
  DateTime time(String key) {
    final micros = integer(key);
    try {
      final value = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
      if (value.microsecondsSinceEpoch != micros) invalid(key);
      return value;
    } on ArgumentError {
      return invalid(key);
    }
  }

  for (final key in recordColumns) {
    if (!row.containsKey(key)) invalid(key);
  }
  if (integer('record_schema_version') != 1) invalid('record_schema_version');
  final identity = OperationIdentity(
    id: text('operation_id'),
    scope: text('scope'),
    type: text('operation_type'),
    idempotencyKey: text('idempotency_key'),
    requestFingerprint: text('request_fingerprint'),
  );
  final state = switch (text('state')) {
    'prepared' => OperationState.prepared,
    'awaiting_outcome' => OperationState.awaitingOutcome,
    'needs_attention' => OperationState.needsAttention,
    'succeeded' => OperationState.succeeded,
    'rejected' => OperationState.rejected,
    _ => invalid('state'),
  };
  final kind = optionalText('observation_kind');
  final reference = optionalText('backend_reference');
  final code = optionalText('rejection_code');
  final reason = optionalText('lookup_failure_reason');
  if ((kind != 'succeeded' && reference != null) ||
      (kind != 'rejected' && code != null) ||
      (kind != 'unavailable' && reason != null)) {
    invalid('observation');
  }
  final observation = switch (kind) {
    null => null,
    'succeeded' => OperationSucceeded(
      identity: identity,
      backendReference: reference,
    ),
    'rejected' => OperationRejected(identity: identity, code: code),
    'pending' => OperationPending(identity: identity),
    'unknown' => OperationUnknown(identity: identity),
    'unavailable' => LookupUnavailable(
      identity: identity,
      reason: switch (reason) {
        'authentication_required' => LookupFailureReason.authenticationRequired,
        'transport_failure' => LookupFailureReason.transportFailure,
        'service_unavailable' => LookupFailureReason.serviceUnavailable,
        _ => invalid('lookup_failure_reason'),
      },
    ),
    _ => invalid('observation_kind'),
  };
  return OperationRecord.restore(
    identity: identity,
    state: state,
    version: integer('record_version'),
    createdAt: time('created_at_us'),
    updatedAt: time('updated_at_us'),
    lastObservation: observation,
    recovery: RecoveryMetadata.restore(
      cycleAttempts: integer('cycle_attempts'),
      totalAttempts: integer('total_attempts'),
      lastAttemptAt: row['last_attempt_at_us'] == null
          ? null
          : time('last_attempt_at_us'),
      nextCheckAt: row['next_check_at_us'] == null
          ? null
          : time('next_check_at_us'),
    ),
  );
}
