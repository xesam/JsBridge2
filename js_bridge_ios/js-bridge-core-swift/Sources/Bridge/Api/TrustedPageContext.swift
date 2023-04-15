public struct TrustedPageContext: Equatable {
    public let origin: String
    public let pageInstanceId: String

    public init(origin: String, pageInstanceId: String) {
        self.origin = origin
        self.pageInstanceId = pageInstanceId
    }
}
