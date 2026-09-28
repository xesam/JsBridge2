export { BridgeError } from './src/main/ets/api/BridgeError';
export { BridgeApiContract } from './src/main/ets/api/BridgeApiContract';
export { BridgeMessage, BridgeMessageKind } from './src/main/ets/api/BridgeMessage';
export { TrustedPageContext } from './src/main/ets/api/TrustedPageContext';
export { OriginNormalizer } from './src/main/ets/api/OriginNormalizer';
export {
  BridgeHandlerResult,
  BridgeTransport,
  CoreBridge,
  Result,
  SimpleHandler,
  AsyncHandler,
  ResponseEmitter
} from './src/main/ets/core/CoreBridge';
/**
 * 生产 API 面：
 * - JsBridge.bindTransport() — 生产路径，origin 由 PageContextProvider 派生（可信）
 * - JsBridge.postEvent() / registerSimpleHandler() / registerAsyncHandler() — 业务 API
 *
 * 测试注入面（不导出到公开 API 面，但类上仍可见）：
 * - JsBridge.processIncomingResponses(messageJson, origin) — 测试专用，生产代码禁用
 * - JsBridge.processIncomingResponsesForContext(messageJson, context) — 测试专用，生产代码禁用
 *
 * ⚠️ 生产代码必须使用 bindTransport()。测试注入面允许外部 origin 注入，
 * 仅供单元测试使用，生产环境存在安全风险。
 */
export {
  ExtraPolicy,
  SecurityConfig,
  JsBridgeOptions,
  JsBridge
} from './src/main/ets/JsBridge';
export { SessionRecord } from './src/main/ets/security/SessionRecord';
export { SessionService } from './src/main/ets/security/SessionService';
export { PageContextProvider } from './src/main/ets/security/PageContextProvider';
export {
  PolicyInput,
  PolicyRule,
  PolicyDecision,
  PolicyEngine,
  RequestShapePolicy,
  HandshakeGatePolicy,
  OriginPolicy,
  MethodGatePolicy,
  SessionPolicy
} from './src/main/ets/security/PolicyEngine';
export { LifecycleExtension } from './src/main/ets/extensions/LifecycleExtension';
