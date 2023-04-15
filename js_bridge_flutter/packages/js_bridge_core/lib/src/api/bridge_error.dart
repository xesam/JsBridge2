class BridgeError {
  const BridgeError({
    required this.code,
    required this.message,
    this.retryable = false,
    this.details = const <String, dynamic>{},
  });

  final String code;
  final String message;
  final bool retryable;
  final Map<String, dynamic> details;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code,
      'message': message,
      'retryable': retryable,
      'details': details,
    };
  }
}
