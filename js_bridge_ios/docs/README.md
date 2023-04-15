# iOS Bridge Docs

## Alignment Rule
- iOS implementation MUST follow:
  - `docs/cross-platform/spec/protocol-v1.md`
  - `docs/cross-platform/spec/error-codes.md`
  - `docs/cross-platform/spec/policy-contract.md`
  - `docs/cross-platform/spec/conformance-cases.md`

## Conformance Rule
- Case ids must remain `C01~C18`.
- Do not rename case ids; only add new ids after baseline set.

## MVP Scope
- Build iOS core MVP for:
  - handshake/session/capability
  - policy chain baseline
  - basic request/response routing
