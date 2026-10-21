import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';

import 'protocol.dart';

final class CrashBackend {
  CrashBackend(this.channel);
  final WorkerChannel channel;
  late final HttpServer _server;
  final Map<String, OperationIdentity> _effects = {};
  final Completer<void> _release = Completer<void>();
  bool pauseSubmission = false;
  bool loseResponse = true;
  bool lookupUnknown = false;
  int submissions = 0;
  int effects = 0;
  int lookups = 0;

  Map<String, Object?> get counters => {
    'submissions': submissions,
    'effects': effects,
    'lookups': lookups,
  };

  Future<void> run() async {
    final init = await channel.next();
    pauseSubmission = init['pauseSubmission'] == true;
    loseResponse = init['loseResponse'] != false;
    lookupUnknown = init['lookupUnknown'] == true;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) {
      unawaited(_respond(request));
    });
    await channel.emit({
      'kind': 'result',
      'seq': init['seq'],
      'uri': 'http://127.0.0.1:${_server.port}',
    });
    try {
      while (true) {
        final command = await channel.next();
        switch (command['action']) {
          case 'stats':
            await channel.emit({
              'kind': 'result',
              'seq': command['seq'],
              ...counters,
            });
          case 'release':
            if (!_release.isCompleted) _release.complete();
            await channel.emit({'kind': 'result', 'seq': command['seq']});
          case 'visibility':
            lookupUnknown = command['unknown'] == true;
            await channel.emit({'kind': 'result', 'seq': command['seq']});
          case 'exit':
            await channel.emit({'kind': 'result', 'seq': command['seq']});
            return;
          default:
            throw StateError('Unsupported backend control action');
        }
      }
    } finally {
      if (!_release.isCompleted) _release.complete();
      await _server.close(force: true);
    }
  }

  Future<void> _respond(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/operations') {
        submissions++;
        final body = jsonObject(await utf8.decoder.bind(request).join());
        final identity = identityFromJson(body);
        await channel.emit({
          'kind': 'checkpoint',
          'name': 'submission-received',
        });
        if (pauseSubmission) await _release.future;
        final previous = _effects[identity.id];
        if (previous != null && previous != identity) {
          request.response.statusCode = HttpStatus.conflict;
          await request.response.close();
          return;
        }
        if (previous == null) {
          _effects[identity.id] = identity;
          effects++;
        }
        await channel.emit({'kind': 'checkpoint', 'name': 'effect-committed'});
        if (loseResponse) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
        } else {
          await _success(request.response, identity);
        }
        return;
      }
      if (request.method == 'GET' &&
          request.uri.pathSegments.firstOrNull == 'operations') {
        lookups++;
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer demo-token') {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        final identity = _effects[request.uri.pathSegments.last];
        if (identity == null ||
            lookupUnknown ||
            identity.scope != request.uri.queryParameters['scope']) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        } else {
          await _success(request.response, identity);
        }
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } on IOException {
      // A killed client cannot cancel a committed backend effect.
    } catch (_) {
      await channel.emit({
        'kind': 'backend-error',
        'message': 'Invalid demo request',
      });
      request.response.statusCode = HttpStatus.badRequest;
      try {
        await request.response.close();
      } on IOException {
        /* disconnected */
      }
    }
  }

  Future<void> _success(
    HttpResponse response,
    OperationIdentity identity,
  ) async {
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode({...identityJson(identity), 'reference': 'tx-crash-demo'}),
    );
    await response.close();
  }
}

final class CrashHttpHandler implements OperationHandler<String> {
  CrashHttpHandler(this.uri, {this.beforeSubmission, this.afterLostResponse});
  final Uri uri;
  final Future<void> Function()? beforeSubmission;
  final Future<void> Function()? afterLostResponse;
  bool authenticated = true;

  @override
  Future<BackendObservation> submit(
    OperationIdentity identity,
    String request,
  ) async {
    await beforeSubmission?.call();
    return _request(identity, payload: request);
  }

  @override
  Future<BackendObservation> lookupStatus(OperationIdentity identity) =>
      _request(identity);

  Future<BackendObservation> _request(
    OperationIdentity identity, {
    String? payload,
  }) async {
    const deadline = Duration(seconds: 30);
    final client = HttpClient()..connectionTimeout = deadline;
    client.authenticate = (_, _, _) async => false;
    client.authenticateProxy = (_, _, _, _) async => false;
    final submitting = payload != null;
    try {
      final target = submitting
          ? uri.resolve('/operations')
          : uri
                .resolve('/operations/${Uri.encodeComponent(identity.id)}')
                .replace(queryParameters: {'scope': identity.scope});
      final request = await client
          .openUrl(submitting ? 'POST' : 'GET', target)
          .timeout(deadline);
      request.followRedirects = false;
      request.persistentConnection = false;
      if (authenticated) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer demo-token',
        );
      }
      if (submitting) {
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({...identityJson(identity), 'payload': payload}),
        );
      }
      final response = await request.close().timeout(deadline);
      final body = await utf8.decoder.bind(response).join().timeout(deadline);
      if (response.statusCode == HttpStatus.unauthorized) {
        return LookupUnavailable(
          identity: identity,
          reason: LookupFailureReason.authenticationRequired,
        );
      }
      if (response.statusCode == HttpStatus.notFound) {
        return OperationUnknown(identity: identity);
      }
      if (response.statusCode != HttpStatus.ok) {
        return LookupUnavailable(
          identity: identity,
          reason: LookupFailureReason.serviceUnavailable,
        );
      }
      final data = jsonObject(body);
      final observedIdentity = identityFromJson(data);
      identity.requireMatch(observedIdentity);
      return OperationSucceeded(
        identity: observedIdentity,
        backendReference: data['reference']! as String,
      );
    } on IOException {
      if (submitting) await afterLostResponse?.call();
      return submitting
          ? OperationUnknown(identity: identity)
          : LookupUnavailable(
              identity: identity,
              reason: LookupFailureReason.transportFailure,
            );
    } finally {
      client.close(force: true);
    }
  }
}
