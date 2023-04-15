import Foundation

public protocol SessionServiceProtocol: AnyObject {
    func issue(context: TrustedPageContext, capabilities: Set<String>, ttlMs: Int64) -> SessionRecord
    func find(sessionId: String) -> SessionRecord?
    func clear(pageInstanceId: String)
    func clearAll()
}
