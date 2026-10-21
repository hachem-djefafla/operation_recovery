import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import 'operation_store_contract.dart';

void main() {
  operationStoreContract(
    'MemoryOperationStore contract',
    MemoryOperationStore.new,
  );

  test(
    'independent memory instances do not share or restore records',
    () async {
      final first = MemoryOperationStore();
      expect(
        await first.createIfAbsent(recordIn(OperationState.prepared)),
        isTrue,
      );
      final second = MemoryOperationStore();
      expect(
        await second.read(id: identity().id, scope: identity().scope),
        isNull,
      );
      expect(await second.listUnresolved(scope: identity().scope), isEmpty);
    },
  );
}
