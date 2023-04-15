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
  String get name;
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
  String get name => 'RequestShapePolicy';

  @override
  BridgeError? evaluate(PolicyInput input) {
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
  String get name => 'HandshakeGatePolicy';

  @override
  BridgeError? evaluate(PolicyInput input) {
    if (!input.ready && input.message.method != BridgeApiContract.methodHandshake) {
      return const BridgeError(
        code: BridgeApiContract.errorPolicyDeny,
        message: 'bridge not ready',
      );
    }
    return null;
  }
}

class AccessControlPolicy implements PolicyRule {
  const AccessControlPolicy({
    required this.allowedOrigins,
    required this.methodWhitelist,
  });

  final Set<String> allowedOrigins;
  final Set<String> methodWhitelist;

  @override
  String get name => 'AccessControlPolicy';

  @override
  BridgeError? evaluate(PolicyInput input) {
    if (!_originAllowed(input.context.origin)) {
      return const BridgeError(
        code: BridgeApiContract.errorOriginDeny,
        message: 'origin denied',
      );
    }

    if (input.message.method == BridgeApiContract.methodHandshake) {
      return null;
    }

    if (!methodWhitelist.contains(input.message.method)) {
      return const BridgeError(
        code: BridgeApiContract.errorMethodNotAllowed,
        message: 'method not allowed',
      );
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
    if (!session.capabilities.contains(input.message.method)) {
      return const BridgeError(
        code: BridgeApiContract.errorCapabilityDeny,
        message: 'capability denied',
      );
    }
    return null;
  }

  bool _originAllowed(String origin) {
    return allowedOrigins.contains('*') || allowedOrigins.contains(origin);
  }
}
