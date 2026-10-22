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

  test('graceful close resumes paused input and observes parent EOF', () async {
    final consumer = _ControlledConsumer()..release.complete();
    final sink = IOSink(consumer);
    final shutdownRead = Completer<String>();
    var shuttingDown = false;
    final input = StreamController<List<int>>(
      onResume: () {
        if (shuttingDown && !shutdownRead.isCompleted) {
          shutdownRead.complete('resumed');
        }
      },
      onCancel: () {
        if (shuttingDown && !shutdownRead.isCompleted) {
          shutdownRead.complete('cancelled');
        }
      },
    );
    final channel = WorkerChannel(input: input.stream, output: sink);
    addTearDown(() async {
      final closing = channel.close();
      await input.close();
      await closing;
      await sink.close();
    });
    final command = channel.next();
    input.add(utf8.encode('{"action":"exit"}\n'));
    expect((await command)['action'], 'exit');
    await channel.emit({'kind': 'result'});
    expect(input.isPaused, isTrue);

    shuttingDown = true;
    var closed = false;
    final closing = channel.close()..then((_) => closed = true);

    expect(await shutdownRead.future, 'resumed');
    expect(closed, isFalse);
    await input.close();
    await closing;
    expect(closed, isTrue);
  });

  test('graceful close rejects control commands after shutdown', () async {
    final consumer = _ControlledConsumer()..release.complete();
    final sink = IOSink(consumer);
    final input = StreamController<List<int>>();
    final channel = WorkerChannel(input: input.stream, output: sink);
    addTearDown(() async {
      await input.close();
      await sink.close();
    });
    final command = channel.next();
    input.add(utf8.encode('{"action":"exit"}\n'));
    await command;
    await channel.emit({'kind': 'result'});

    final closing = expectLater(channel.close(), throwsStateError);
    input.add(utf8.encode('{"action":"stats"}\n'));

    await closing;
    expect(input.hasListener, isFalse);
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
