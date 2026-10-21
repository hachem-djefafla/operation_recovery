import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/support/protocol.dart';

void main() {
  test(
    'concurrent emissions serialize write and flush without interleaving',
    () async {
      final consumer = _ControlledConsumer();
      final sink = IOSink(consumer);
      final channel = WorkerChannel(input: const Stream.empty(), output: sink);
      addTearDown(() async {
        if (!consumer.release.isCompleted) consumer.release.complete();
        await channel.close();
        await sink.close();
      });
      final first = channel.emit({'kind': 'checkpoint', 'number': 1});
      await consumer.firstFlush.future;
      final second = channel.emit({'kind': 'result', 'number': 2});
      final third = channel.emit({'kind': 'checkpoint', 'number': 3});
      consumer.release.complete();
      await Future.wait([first, second, third]);
      expect(
        const LineSplitter()
            .convert(utf8.decode(consumer.bytes))
            .map(jsonObject)
            .toList(),
        [
          {'kind': 'checkpoint', 'number': 1},
          {'kind': 'result', 'number': 2},
          {'kind': 'checkpoint', 'number': 3},
        ],
      );
    },
  );

  test('close drains queued messages and rejects later emission', () async {
    final consumer = _ControlledConsumer();
    final sink = IOSink(consumer);
    final channel = WorkerChannel(input: const Stream.empty(), output: sink);
    addTearDown(sink.close);
    final emission = channel.emit({'kind': 'result'});
    await consumer.firstFlush.future;
    var closed = false;
    final closing = channel.close()..then((_) => closed = true);
    expect(closed, isFalse);
    await expectLater(channel.emit({'late': true}), throwsStateError);
    consumer.release.complete();
    await emission;
    await closing;
    expect(closed, isTrue);
    expect(identical(channel.close(), closing), isTrue);
  });

  test(
    'output failures propagate instead of acknowledging later messages',
    () async {
      final consumer = _ControlledConsumer();
      final sink = IOSink(consumer);
      final channel = WorkerChannel(input: const Stream.empty(), output: sink);
      final first = channel.emit({'kind': 'checkpoint'});
      final firstError = expectLater(first, throwsStateError);
      await consumer.firstFlush.future;
      final nextError = expectLater(
        channel.emit({'kind': 'result'}),
        throwsStateError,
      );
      consumer.release.completeError(StateError('injected output failure'));
      await Future.wait([firstError, nextError]);
      await expectLater(channel.close(), throwsStateError);
      await sink.close();
    },
  );
}

final class _ControlledConsumer implements StreamConsumer<List<int>> {
  final bytes = <int>[];
  final firstFlush = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    if (!firstFlush.isCompleted) firstFlush.complete();
    await release.future;
  }

  @override
  Future<void> close() async {}
}
