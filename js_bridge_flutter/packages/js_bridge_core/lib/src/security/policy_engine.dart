import '../api/bridge_api_contract.dart';
import '../api/bridge_error.dart';
import '../api/bridge_message.dart';
import 'session_record.dart';
import '../api/trusted_page_context.dart';

class PolicyInput {
  const PolicyInput({
    required this.message,
    required this.context,
    required this.ready,
    required this.sessionRecord,
  });

  final BridgeMessage message;
  final TrustedPageContext context;
  final bool ready;
  final SessionRecord? sessionRecord;
}

abstract class PolicyRule {
  BridgeError? evaluate(PolicyInput input);
}

class PolicyEngine {
  PolicyEngine(List<PolicyRule> rules) : rules = List.unmodifiable(rules);
  final List<PolicyRule> rules;

  BridgeError? evaluate(PolicyInput input) {
    for (final PolicyRule rule in rules) {
      final BridgeError? err = rule.evaluate(input);
      if (err != null) return err;
    }
    return null;
  }
}

class RequestShapePolicy implements PolicyRule {
  const RequestShapePolicy();

  @override
  BridgeError? evaluate(PolicyInput input) {
    if (input.message.method.isEmpty) {
      return const BridgeError(
        code: BridgeApiContract.errorInvalidMessage,
        message: 'method is required',
      );
    }
    if (input.message.kind != BridgeMessageKind.request) {
      return const BridgeError(
        code: BridgeApiContract.errorInvalidMessage,
        message: 'only request messages are accepted',
      );
    }
    return null;
  }
}

class HandshakeGatePolicy implements PolicyRule {
  const HandshakeGatePolicy();

  @override
  BridgeError? evaluate(PolicyInput input) {
    if (!input.ready && input.message.method != BridgeApiContract.methodHandshake) {
      return const BridgeError(
        code: BridgeApiContract.errorNotReady,
        message: 'bridge session not ready',
      );
    }
    return null;
  }
}

class OriginPolicy implements PolicyRule {
  const OriginPolicy({required this.allowedOrigins});

  final Set<String> allowedOrigins;

  @override
  BridgeError? evaluate(PolicyInput input) {
    if (!allowedOrigins.contains(input.context.origin)) {
      return const BridgeError(
        code: BridgeApiContract.errorOriginDeny,
        message: 'origin denied',
      );
    }
    return null;
  }
}

class MethodGatePolicy implements PolicyRule {
  const MethodGatePolicy({required this.methodWhitelist});

  final Set<String> methodWhitelist;

  @override
  BridgeError? evaluate(PolicyInput input) {
    if (!methodWhitelist.contains(input.message.method)) {
      return const BridgeError(
        code: BridgeApiContract.errorMethodNotAllowed,
        message: 'method not allowed',
      );
    }
    return null;
  }
}

class SessionPolicy implements PolicyRule {
  const SessionPolicy();

  @override
  BridgeError? evaluate(PolicyInput input) {
    if (input.message.method == BridgeApiContract.methodHandshake) {
      return null;
    }
    final SessionRecord? session = input.sessionRecord;
    if (session == null) {
      return const BridgeError(
        code: BridgeApiContract.errorSessionInvalid,
        message: 'session invalid',
      );
    }
    if (session.context.origin != input.context.origin ||
        session.context.pageInstanceId != input.context.pageInstanceId) {
      return const BridgeError(
        code: BridgeApiContract.errorSessionInvalid,
        message: 'session context mismatch',
      );
    }
    return null;
  }
}
