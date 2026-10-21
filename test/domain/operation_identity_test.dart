import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('identity validation', () {
    final fields = <String, OperationIdentity Function(String)>{
      'id': (value) => identity(id: value),
      'scope': (value) => identity(scope: value),
      'type': (value) => identity(type: value),
      'idempotencyKey': (value) => identity(idempotencyKey: value),
      'requestFingerprint': (value) => identity(requestFingerprint: value),
    };
    for (final entry in fields.entries) {
      for (final blank in ['', ' ', '\t\n']) {
        test('${entry.key} rejects ${blank.codeUnits}', () {
          expect(
            () => entry.value(blank),
            throwsA(
              isA<InvalidOperationRecordException>().having(
                (error) => error.field,
                'field',
                entry.key,
              ),
            ),
          );
        });
      }
      test('${entry.key} participates in equality and conflict checks', () {
        final original = identity();
        final changed = entry.value('different');
        expect(changed, isNot(original));
        expect(
          () => original.requireMatch(changed),
          throwsA(isA<OperationIdentityConflictException>()),
        );
      });
    }

    test('equal identities compare by value and share hash code', () {
      final first = identity();
      final second = identity();
      expect(identical(first, second), isFalse);
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect({first, second}, hasLength(1));
      expect(() => first.requireMatch(second), returnsNormally);
      expect(first == Object(), isFalse);
    });

    test('values are preserved without trimming or case folding', () {
      final original = identity(id: ' Op-123 ');
      expect(original.id, ' Op-123 ');
      expect(original, isNot(identity(id: 'op-123')));
      expect(original, isNot(identity(id: 'Op-123')));
    });

    test('default identity representation redacts every value', () {
      final value = identity();
      for (final secret in [
        value.id,
        value.scope,
        value.type,
        value.idempotencyKey,
        value.requestFingerprint,
      ]) {
        expect(value.toString(), isNot(contains(secret)));
      }
    });
  });
}
