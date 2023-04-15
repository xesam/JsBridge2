/// 共享上下文数据模型，跨层使用。纯数据，无逻辑。
class TrustedPageContext {
  const TrustedPageContext({
    required this.origin,
    required this.pageInstanceId,
  });

  final String origin;
  final String pageInstanceId;
}
