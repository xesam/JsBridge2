import 'dart:convert';

import 'bridge_error.dart';

enum BridgeMessageKind { request, response, event }

class BridgeMessage {
  BridgeMessage({
    required this.id,
    required this.sessionId,
    required this.kind,
    required this.method,
    required this.ts,
    this.timeoutMs = 0,
    this.keep = false,
    this.payload,
    this.reqId,
    this.done,
    this.ok,
    this.error,
    this.scopeId,
  });

  final String id;
  final String sessionId;
  final BridgeMessageKind kind;
  final String method;
  final int ts;
  final int timeoutMs;
  final bool keep;
  final dynamic payload;
  final String? reqId;
  final bool? done;
  final bool? ok;
  final BridgeError? error;
  final String? scopeId;

  factory BridgeMessage.fromJsonString(String raw) {
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    return BridgeMessage(
      id: _requiredString(json['id'], 'id'),
      sessionId: _optionalSessionId(json['sessionId']),
      kind: _parseKindStrict(json['kind']),
      method: _requiredString(json['method'], 'method'),
      ts: (json['ts'] as num?)?.toInt() ?? 0,
      timeoutMs: (json['timeoutMs'] as num?)?.toInt() ?? 0,
      keep: json['keep'] == true,
      payload: json['payload'],
      reqId: json['reqId'] as String?,
      done: json['done'] as bool?,
      ok: json['ok'] as bool?,
      error: _parseError(json['error']),
      scopeId: json['scopeId'] as String?,
    );
  }

  String toJsonString() {
    return jsonEncode(toJson());
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'sessionId': sessionId,
      'kind': kind.name,
      'method': method,
      'ts': ts,
      'timeoutMs': timeoutMs,
      'keep': keep,
      'payload': payload,
      'reqId': reqId,
      'done': done,
      'ok': ok,
      'error': error?.toJson(),
      if (scopeId != null) 'scopeId': scopeId,
    };
  }

  static BridgeMessageKind _parseKindStrict(dynamic raw) {
    switch (raw) {
      case 'request':
        return BridgeMessageKind.request;
      case 'response':
        return BridgeMessageKind.response;
      case 'event':
        return BridgeMessageKind.event;
      default:
        throw const FormatException('BridgeMessage: invalid kind');
    }
  }

  static String _requiredString(dynamic raw, String field) {
    if (raw is! String) {
      throw FormatException('BridgeMessage: field $field must be a string');
    }
    return raw;
  }

  static String _optionalSessionId(dynamic raw) {
    if (raw == null) {
      return '';
    }
    if (raw is! String) {
      throw const FormatException('BridgeMessage: field sessionId must be a string');
    }
    return raw;
  }

  static BridgeError? _parseError(dynamic raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    return BridgeError(
      code: raw['code'] as String? ?? 'E_INTERNAL',
      message: raw['message'] as String? ?? 'unknown error',
      retryable: raw['retryable'] == true,
      details: (raw['details'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }
}
