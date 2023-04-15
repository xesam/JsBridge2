public protocol BridgeTransport: AnyObject {
    func bind(listener: @escaping (String) -> Void)
    @discardableResult
    func send(_ messageJson: String) -> Bool
    func close()
}
