import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';

/// Demonstration server only, with memory state independent of the client store.
/// It counts received submissions separately from deduplicated business effects.
final class SimulatedBackend {
  SimulatedBackend._(this._server, this.loseSubmissionResponse);

  /// Binds only loopback, with no database or background process.
  static Future<SimulatedBackend> start({
    bool loseSubmissionResponse = true,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final backend = SimulatedBackend._(server, loseSubmissionResponse);
    server.listen(backend._respond);
    return backend;
  }

  final HttpServer _server;

  /// Whether to sever the connection after executing the submission.
  final bool loseSubmissionResponse;

  /// Incoming POST count, including any accidental duplicate request.
  int submissionRequests = 0;

  /// Distinct backend effects after ID-based deduplication.
  int effects = 0;

  /// Incoming lookup count, including unauthorized requests.
  int lookupRequests = 0;

  final Map<(String, String), OperationIdentity> _operations = {};

  /// The ephemeral local endpoint.
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _respond(HttpRequest request) async {
    if (request.method == 'POST' && request.uri.path == '/operations') {
      submissionRequests++;
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      final identity = _decodeIdentity(body);
      final key = (identity.scope, identity.id);
      final previous = _operations[key];
      if (previous == null) {
        _operations[key] = identity;
        effects++;
      } else if (previous != identity) {
        request.response.statusCode = HttpStatus.conflict;
        await request.response.close();
        return;
      }
      if (loseSubmissionResponse) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      await _success(request.response, identity);
      return;
    }
    if (request.method == 'GET') {
      lookupRequests++;
      // A demo flag, not a production authorization model.
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer demo-token') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final id = request.uri.pathSegments.last;
      final scope = request.uri.queryParameters['scope'];
      final identity = _operations[(scope, id)];
      if (identity == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } else {
        await _success(request.response, identity);
      }
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _success(
    HttpResponse response,
    OperationIdentity identity,
  ) async {
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode({..._encodeIdentity(identity), 'reference': 'tx-demo'}),
    );
    await response.close();
  }

  /// Stops the local demo server; the engine never calls this resource method.
  Future<void> close() async => _server.close(force: true);
}

/// Test/example HTTP integration; no networking dependency enters the core.
/// New clients, disabled redirects/auth retries, and no application retry loop
/// keep submission intentional. Deadlines and socket cleanup belong here.
final class DemoHttpHandler implements OperationHandler<String> {
  /// Creates an application-owned handler for the local demonstration server.
  DemoHttpHandler(this.baseUri);

  /// The simulated backend endpoint.
  final Uri baseUri;

  /// Simulates application-owned authentication restoration during lookup.
  bool authenticated = true;

  @override
  Future<BackendObservation> submit(
    OperationIdentity identity,
    String request,
  ) => _request(identity, 'POST', baseUri.resolve('/operations'), request);

  @override
  Future<BackendObservation> lookupStatus(OperationIdentity identity) =>
      _request(
        identity,
        'GET',
        baseUri
            .resolve('/operations/${Uri.encodeComponent(identity.id)}')
            .replace(queryParameters: {'scope': identity.scope}),
        null,
      );

  Future<BackendObservation> _request(
    OperationIdentity identity,
    String method,
    Uri uri,
    String? payload,
  ) async {
    const deadline = Duration(seconds: 5);
    final client = HttpClient()..connectionTimeout = deadline;
    client.authenticate = (_, _, _) async => false;
    client.authenticateProxy = (_, _, _, _) async => false;
    try {
      final request = await client.openUrl(method, uri).timeout(deadline);
      request.followRedirects = false;
      request.persistentConnection = false;
      if (authenticated) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer demo-token',
        );
      }
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({..._encodeIdentity(identity), 'payload': payload}),
        );
      }
      final response = await request.close().timeout(deadline);
      final text = await utf8.decoder.bind(response).join().timeout(deadline);
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
      final body = jsonDecode(text) as Map<String, dynamic>;
      final observedIdentity = _decodeIdentity(body);
      identity.requireMatch(observedIdentity);
      return OperationSucceeded(
        identity: observedIdentity,
        backendReference: body['reference'] as String,
      );
    } on IOException {
      return method == 'POST'
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

Map<String, String> _encodeIdentity(OperationIdentity identity) => {
  'id': identity.id,
  'scope': identity.scope,
  'type': identity.type,
  'key': identity.idempotencyKey,
  'fingerprint': identity.requestFingerprint,
};

OperationIdentity _decodeIdentity(Map<String, dynamic> body) =>
    OperationIdentity(
      id: body['id'] as String,
      scope: body['scope'] as String,
      type: body['type'] as String,
      idempotencyKey: body['key'] as String,
      requestFingerprint: body['fingerprint'] as String,
    );
