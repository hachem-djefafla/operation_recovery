import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test('only success and rejection assert authority', () {
    final operationIdentity = identity();
    final observations = <BackendObservation, bool>{
      OperationSucceeded(identity: operationIdentity): true,
      OperationRejected(identity: operationIdentity): true,
      OperationPending(identity: operationIdentity): false,
      OperationUnknown(identity: operationIdentity): false,
      for (final reason in LookupFailureReason.values)
        LookupUnavailable(identity: operationIdentity, reason: reason): false,
    };
    for (final entry in observations.entries) {
      expect(entry.key.isAuthoritative, entry.value);
      expect(entry.key.identity, same(operationIdentity));
    }
  });

  for (final blank in ['', ' ', '\t\n']) {
    test('success rejects blank reference ${blank.codeUnits}', () {
      expect(
        () => OperationSucceeded(identity: identity(), backendReference: blank),
        throwsA(
          isA<InvalidBackendObservationException>().having(
            (error) => error.field,
            'field',
            'backendReference',
          ),
        ),
      );
    });
    test('rejection rejects blank code ${blank.codeUnits}', () {
      expect(
        () => OperationRejected(identity: identity(), code: blank),
        throwsA(isA<InvalidBackendObservationException>()),
      );
    });
  }

  test('null and nonblank optional metadata are retained', () {
    expect(OperationSucceeded(identity: identity()).backendReference, isNull);
    expect(OperationRejected(identity: identity()).code, isNull);
    expect(
      OperationSucceeded(
        identity: identity(),
        backendReference: ' tx-123 ',
      ).backendReference,
      ' tx-123 ',
    );
    expect(
      OperationRejected(identity: identity(), code: 'declined').code,
      'declined',
    );
  });

  test('default observation strings omit identity and outcome metadata', () {
    final value = identity();
    final observations = [
      OperationSucceeded(identity: value, backendReference: 'secret-reference'),
      OperationRejected(identity: value, code: 'secret-code'),
      OperationPending(identity: value),
      OperationUnknown(identity: value),
      LookupUnavailable(
        identity: value,
        reason: LookupFailureReason.authenticationRequired,
      ),
    ];
    for (final observation in observations) {
      for (final secret in [
        value.id,
        value.scope,
        value.type,
        value.idempotencyKey,
        value.requestFingerprint,
        'secret-reference',
        'secret-code',
      ]) {
        expect(observation.toString(), isNot(contains(secret)));
      }
    }
  });
}
