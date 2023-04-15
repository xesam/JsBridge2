# Extension Guide

## Scope
`js-bridge` core only guarantees protocol flow and extension points. Product-specific policy and business logic must be implemented by callers.

## Stable SPI
1. Transport SPI: `core.transport.BridgeTransport`
- `bind(listener)`: receive inbound JSON messages.
- `send(messageJson)`: send outbound JSON messages.
- `close()`: release channel resources.

2. Context SPI: `security.context.PageContextProvider`
- `createContext(...)` returns `TrustedPageContext` (`origin`, `pageInstanceId`).
- Provider is responsible for producing trusted host metadata.

3. Policy SPI: `security.policy.PolicyRule`
- Add custom rules via `JsBridge.SecurityConfig.extraPolicies(...)`.
- Built-in baseline remains: request shape, handshake gate, access control/session binding.

4. Activity result SPI:
- `extensions.registry.BridgeResultRegistry` for launching.
- `extensions.registry.BridgeResultDispatcher` only for compat hosts needing `onActivityResult` dispatch.
- Single-flight contract: one in-flight launch per registry instance.

## Security Defaults
- `JsBridge.SecurityConfig.allowedOrigins` default is `["*"]`.
- This default is for compatibility/bootstrap only; production hosts should always set an explicit allowlist.

## Threading & Delivery Notes
- `JsBridge` supports basic concurrent access for handler/listener registration and request handling.
- Host integration should still keep bridge lifecycle APIs (`resetForNewPage`, `destroy`, `registerNativeHandler`) on one serial thread (typically main thread) to avoid races with page lifecycle.
- When transport `send(...)` returns `false`, bridge treats it as a delivery failure and logs a warning; hosts should collect these logs for observability.

## Result/Error Semantics
`BridgeLaunchResult` exposes normalized launch errors:
- `busy`: launch already in progress (`E_BUSY`).
- `canceled`: user/system canceled (`E_CANCELED`).
- `nothing`: no data returned (`E_RESULT_EMPTY`).
- other failures should map to `E_LAUNCH_FAILED`.

## Compatibility Rules
1. Do not change `api/model` field names or remove existing fields.
2. Keep `BridgeApiContract` method names stable.
3. Additive changes only for `0.0.x`.
