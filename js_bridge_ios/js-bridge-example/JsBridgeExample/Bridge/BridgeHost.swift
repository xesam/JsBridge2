import Foundation
import WebKit
import BridgeCore
import BridgeSystem
import UIKit
import CoreLocation

final class BridgeHost: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate, CLLocationManagerDelegate {
    private let transport: WKWebViewBridgeTransport
    private let bridge: JsBridge
    private var loadingAlert: UIAlertController?
    private var timerRunning: Bool = false
    private var timerCounter: Int = 0
    private var activeTimer: Timer?
    private var imagePickCompletion: ((Result<String, BridgeError>) -> Void)?
    private var locationManager: CLLocationManager?
    private var locationAuthCompletion: ((CLAuthorizationStatus) -> Void)?
    private var locationResultCompletion: ((Result<CLLocation, BridgeError>) -> Void)?
    private var locationTimeoutWorkItem: DispatchWorkItem?
    private var lifecycleExtension: LifecycleExtension?

    init(webView: WKWebView) {
        var config = JsBridge.SecurityConfig()
        config.allowedOrigins = ["file://", "https://example.com"]
        // methodWhitelist 语义为业务方法白名单，协议方法（bridge.handshake 等）由框架自动放行
        config.methodWhitelist = [
            "getUser",
            "request",
            "timerLog",
            "showLoading",
            "getCurrentLocation",
            "pickImage",
            "pickInput"
        ]
        self.transport = WKWebViewBridgeTransport(webView: webView)
        self.bridge = JsBridge(securityConfig: config, pageContextProvider: WebViewPageContextProvider(webView: webView), transport: transport)
        super.init()
        bridge.bindTransport()
        bridge.resetPageInstance()
        lifecycleExtension = LifecycleExtension(bridge: bridge)
        registerLifecycleObservers()
        registerHandlers()
        lifecycleExtension?.onHostEvent(state: "created")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        lifecycleExtension?.onHostEvent(state: "destroyed")
    }

    private func registerHandlers() {
        bridge.registerSimpleHandler(method: "getUser") { _, payload in
            guard let object = payload?.asObject else {
                return .failure(BridgeError(code: "E_INVALID_MESSAGE", message: "invalid payload"))
            }
            let userId = object["userId"]?.asString
            if userId == "001" {
                return .success(.object(["name": .string("xesam")]))
            }
            return .failure(BridgeError(
                code: "E_NOT_FOUND",
                message: "user not found",
                details: ["userId": userId ?? ""]
            ))
        }

        bridge.registerSimpleHandler(method: "request") { [weak self] _, payload in
            guard let self else {
                return .failure(BridgeError(code: "E_INTERNAL", message: "bridge host released"))
            }
            guard
                let object = payload?.asObject,
                let urlString = object["url"]?.asString,
                URL(string: urlString) != nil
            else {
                return .failure(BridgeError(code: "E_INVALID_PAYLOAD", message: "request.url is required"))
            }
            return self.performGetRequest(urlString: urlString).asHandlerResult
        }

        // timerLog: 使用 AsyncHandler 实现真正的无限 streaming
        bridge.registerAsyncHandler(method: "timerLog") { [weak self] _, payload, emitter in
            guard let self else {
                if let emitter {
                    await emitter(.failure(BridgeError(code: "E_INTERNAL", message: "bridge host released")), true)
                }
                return
            }

            guard let emitter else { return }

            let action = payload?.asObject?["action"]?.asString ?? "start"

            if action == "start" {
                if self.timerRunning {
                    await emitter(.failure(BridgeError(code: "E_INVALID_PAYLOAD", message: "Timer is already running.")), true)
                    return
                }

                self.timerRunning = true

                // 启动后台 Timer 实现真正的无限 streaming
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                    guard let self else {
                        timer.invalidate()
                        return
                    }

                    if !self.timerRunning {
                        timer.invalidate()
                        Task {
                            await emitter(.success(.object([
                                "event": .string("stopped"),
                                "running": .bool(false)
                            ])), true)
                        }
                        return
                    }

                    self.timerCounter += 1
                    Task {
                        await emitter(.success(.object([
                            "event": .string("tick"),
                            "value": .number(Double(Int.random(in: 0..<100))),
                            "seq": .number(Double(self.timerCounter)),
                            "running": .bool(true)
                        ])), false)
                    }
                }

                // 保存 timer 引用以便后续可以停止
                self.activeTimer = timer
                RunLoop.current.add(timer, forMode: .common)

                return
            }

            if action == "stop" {
                self.timerRunning = false
                self.activeTimer?.invalidate()
                self.activeTimer = nil

                await emitter(.success(.object([
                    "event": .string("stopped"),
                    "running": .bool(false)
                ])), true)
                return
            }

            await emitter(.failure(BridgeError(code: "E_INVALID_PAYLOAD", message: "Timer action must be start or stop.")), true)
        }
        bridge.registerSimpleHandler(method: "showLoading") { [weak self] _, payload in
            guard let self else {
                return .failure(BridgeError(code: "E_INTERNAL", message: "bridge host released"))
            }
            let title = payload?.asObject?["title"]?.asString ?? "Loading"
            let content = payload?.asObject?["content"]?.asString ?? "Please wait..."
            let durationMs = payload?.asObject?["durationMs"]?.asDouble ?? 1200.0
            self.presentNativeLoading(title: title, message: content, durationMs: durationMs)
            return .success(.object([
                "status": .string("shown"),
                "native": .bool(true),
                "durationMs": .number(durationMs)
            ]))
        }
        bridge.registerSimpleHandler(method: "getCurrentLocation") { [weak self] _, payload in
            guard let self else {
                return .failure(BridgeError(code: "E_INTERNAL", message: "bridge host released"))
            }
            let object = payload?.asObject ?? [:]
            let accuracy = object["accuracy"]?.asString ?? "coarse"
            let fine = accuracy.lowercased() == "fine"
            var timeoutSeconds = 10.0
            if let timeoutMs = object["timeoutMs"]?.asDouble, timeoutMs > 0 {
                timeoutSeconds = timeoutMs / 1000.0
            }
            if self.locationResultCompletion != nil || self.locationAuthCompletion != nil {
                return .failure(BridgeError(code: "E_BUSY", message: "location request is already in progress"))
            }
            return self.performGetCurrentLocation(fine: fine, timeoutSeconds: timeoutSeconds).asHandlerResult
        }
        bridge.registerSimpleHandler(method: "pickImage") { [weak self] _, payload in
            guard let self else {
                return .failure(BridgeError(code: "E_INTERNAL", message: "bridge host released"))
            }
            let type = payload?.asObject?["type"]?.asString ?? "image/*"
            let pickResult = self.performPickImage()
            switch pickResult {
            case .success(let imageUri):
                return .success(.object([
                    "uri": .string(imageUri),
                    "type": .string(type),
                    "source": .string("photo-library"),
                    "native": .bool(true)
                ]))
            case .failure(let error):
                return .failure(error)
            }
        }
        bridge.registerSimpleHandler(method: "pickInput") { [weak self] _, _ in
            guard let self else {
                return .failure(BridgeError(code: "E_INTERNAL", message: "bridge host released"))
            }
            let inputResult = self.performPickInput()
            switch inputResult {
            case .success(let input):
                return .success(.object([
                    "name": .string(input.name),
                    "age": .number(Double(input.age)),
                    "native": .bool(true)
                ]))
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    private func performGetRequest(urlString: String) -> Result<JSONValue?, BridgeError> {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(BridgeError(code: "E_INVALID_PAYLOAD", message: "request.url must be http/https"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        let semaphore = DispatchSemaphore(value: 0)
        var outputData: Data?
        var outputError: Error?
        var statusCode: Int = 0

        URLSession.shared.dataTask(with: request) { data, response, error in
            outputData = data
            outputError = error
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
            }
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 6) == .timedOut {
            return .failure(BridgeError(code: "E_REQUEST_FAILED", message: "request timeout"))
        }
        if let outputError {
            return .failure(BridgeError(code: "E_REQUEST_FAILED", message: outputError.localizedDescription))
        }

        let body = String(data: outputData ?? Data(), encoding: .utf8) ?? ""
        return .success(.object([
            "code": .number(Double(statusCode)),
            "body": .string(body),
            "url": .string(urlString)
        ]))
    }

    private func presentNativeLoading(title: String, message: String, durationMs: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let top = self.topViewController() else { return }

            self.loadingAlert?.dismiss(animated: false)

            let alert = UIAlertController(title: title, message: "\n\(message)", preferredStyle: .alert)
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.startAnimating()
            alert.view.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 52)
            ])
            self.loadingAlert = alert
            top.present(alert, animated: true)

            let duration = max(0.3, durationMs / 1000.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.loadingAlert?.dismiss(animated: true)
                self?.loadingAlert = nil
            }
        }
    }

    private func performPickImage() -> Result<String, BridgeError> {
        var result: Result<String, BridgeError>?
        runInteractiveDialog(timeoutSeconds: 20) { top, finish in
            guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
                finish(.failure(BridgeError(code: "E_LAUNCH_FAILED", message: "photo library unavailable")))
                return
            }
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.mediaTypes = ["public.image"]
            picker.delegate = self
            self.imagePickCompletion = finish
            top.present(picker, animated: true)
        } completion: { interactiveResult in
            result = interactiveResult
        }
        return result ?? .failure(BridgeError(code: "E_LAUNCH_FAILED", message: "launch failed"))
    }

    private struct PickInputValue {
        let name: String
        let age: Int
    }

    private func performPickInput() -> Result<PickInputValue, BridgeError> {
        var result: Result<PickInputValue, BridgeError>?
        runInteractiveDialog(timeoutSeconds: 60) { top, finish in
            let vc = PickInputViewController { inputResult in
                let mapped = inputResult.map { tuple in
                    PickInputValue(name: tuple.name, age: tuple.age)
                }
                finish(mapped)
            }
            let nav = UINavigationController(rootViewController: vc)
            top.present(nav, animated: true)
        } completion: { interactiveResult in
            result = interactiveResult
        }
        return result ?? .failure(BridgeError(code: "E_LAUNCH_FAILED", message: "launch failed"))
    }

    private func runInteractiveDialog<T>(
        timeoutSeconds: TimeInterval,
        present: @escaping (_ top: UIViewController, _ finish: @escaping (Result<T, BridgeError>) -> Void) -> Void,
        completion: @escaping (Result<T, BridgeError>) -> Void
    ) {
        if Thread.isMainThread {
            guard let top = topViewController() else {
                completion(.failure(BridgeError(code: "E_LAUNCH_FAILED", message: "top view controller not found")))
                return
            }
            var completed = false
            var outcome: Result<T, BridgeError>?
            let finish: (Result<T, BridgeError>) -> Void = { result in
                guard !completed else { return }
                completed = true
                outcome = result
            }
            present(top, finish)
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while !completed && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            if let outcome {
                completion(outcome)
                return
            }
            top.presentedViewController?.dismiss(animated: true)
            completion(.failure(BridgeError(code: "E_REQUEST_FAILED", message: "request timeout")))
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, BridgeError>?
        DispatchQueue.main.async { [weak self] in
            guard let self, let top = self.topViewController() else {
                outcome = .failure(BridgeError(code: "E_LAUNCH_FAILED", message: "top view controller not found"))
                semaphore.signal()
                return
            }
            let finish: (Result<T, BridgeError>) -> Void = { result in
                outcome = result
                semaphore.signal()
            }
            present(top, finish)
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            completion(.failure(BridgeError(code: "E_REQUEST_FAILED", message: "request timeout")))
            return
        }
        completion(outcome ?? .failure(BridgeError(code: "E_LAUNCH_FAILED", message: "launch failed")))
    }

    private func performGetCurrentLocation(fine: Bool, timeoutSeconds: TimeInterval) -> Result<JSONValue?, BridgeError> {
        var result: Result<JSONValue?, BridgeError>?
        awaitAsyncResult(timeoutSeconds: timeoutSeconds + 1.0) { finish in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    finish(.failure(BridgeError(code: "E_INTERNAL", message: "bridge host released")))
                    return
                }
                self.requestCurrentLocationOnMain(fine: fine, timeoutSeconds: timeoutSeconds, finish: finish)
            }
        } completion: { outcome in
            result = outcome
        }
        return result ?? .failure(BridgeError(code: "E_LAUNCH_FAILED", message: "location launch failed"))
    }

    private func requestCurrentLocationOnMain(
        fine: Bool,
        timeoutSeconds: TimeInterval,
        finish: @escaping (Result<JSONValue?, BridgeError>) -> Void
    ) {
        guard CLLocationManager.locationServicesEnabled() else {
            finish(.failure(BridgeError(code: "E_LOCATION_UNAVAILABLE", message: "Location services disabled")))
            return
        }
        let manager = locationManager ?? CLLocationManager()
        locationManager = manager
        manager.delegate = self
        manager.desiredAccuracy = fine ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters

        let completeWithLocation: (CLLocation) -> Void = { [weak self] location in
            self?.clearLocationFlow()
            finish(.success(.object([
                "lat": .number(location.coordinate.latitude),
                "lng": .number(location.coordinate.longitude),
                "accuracy": .number(location.horizontalAccuracy),
                "provider": .string(location.sourceInformation?.isSimulatedBySoftware == true ? "simulated" : "core-location"),
                "timestamp": .number(location.timestamp.timeIntervalSince1970 * 1000)
            ])))
        }
        let completeWithError: (BridgeError) -> Void = { [weak self] error in
            self?.clearLocationFlow()
            finish(.failure(error))
        }

        let status = manager.authorizationStatus
        if status == .denied {
            completeWithError(BridgeError(
                code: "E_PERMISSION_PERMANENTLY_DENIED",
                message: "Location permission denied",
                details: ["canOpenSettings": "true"]
            ))
            return
        }
        if status == .restricted {
            completeWithError(BridgeError(code: "E_PERMISSION_DENIED", message: "Location permission restricted"))
            return
        }

        if let last = manager.location {
            completeWithLocation(last)
            return
        }

        let startUpdating: () -> Void = { [weak self] in
            guard let self else {
                completeWithError(BridgeError(code: "E_INTERNAL", message: "bridge host released"))
                return
            }
            self.locationResultCompletion = { result in
                switch result {
                case .success(let location):
                    completeWithLocation(location)
                case .failure(let error):
                    completeWithError(error)
                }
            }
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard self?.locationResultCompletion != nil else { return }
                self?.locationResultCompletion?(.failure(BridgeError(code: "E_INTERNAL", message: "Location request timeout")))  // 返回 E_INTERNAL 而非 E_TIMEOUT——E_TIMEOUT 为 JS 本地码，不跨端传输（docs/03 §8）
            }
            self.locationTimeoutWorkItem = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)
            self.locationManager?.startUpdatingLocation()
        }

        if status == .notDetermined {
            locationAuthCompletion = { [weak self] authStatus in
                guard let self else { return }
                if authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse {
                    startUpdating()
                    return
                }
                if authStatus == .denied {
                    completeWithError(BridgeError(
                        code: "E_PERMISSION_DENIED",
                        message: "Location permission denied",
                        details: ["canOpenSettings": "true"]
                    ))
                    return
                }
                completeWithError(BridgeError(code: "E_PERMISSION_DENIED", message: "Location permission unavailable"))
                self.clearLocationFlow()
            }
            manager.requestWhenInUseAuthorization()
            return
        }

        startUpdating()
    }

    private func awaitAsyncResult<T>(
        timeoutSeconds: TimeInterval,
        start: (@escaping (Result<T, BridgeError>) -> Void) -> Void,
        completion: @escaping (Result<T, BridgeError>) -> Void
    ) {
        if Thread.isMainThread {
            var done = false
            var outcome: Result<T, BridgeError>?
            start { result in
                guard !done else { return }
                done = true
                outcome = result
            }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while !done && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            if let outcome {
                completion(outcome)
                return
            }
            completion(.failure(BridgeError(code: "E_INTERNAL", message: "operation timeout")))  // 返回 E_INTERNAL 而非 E_TIMEOUT——E_TIMEOUT 为 JS 本地码，不跨端传输（docs/03 §8）
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, BridgeError>?
        start { result in
            outcome = result
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            completion(.failure(BridgeError(code: "E_INTERNAL", message: "operation timeout")))  // 返回 E_INTERNAL 而非 E_TIMEOUT——E_TIMEOUT 为 JS 本地码，不跨端传输（docs/03 §8）
            return
        }
        completion(outcome ?? .failure(BridgeError(code: "E_INTERNAL", message: "missing async result")))
    }

    private func clearLocationFlow() {
        locationTimeoutWorkItem?.cancel()
        locationTimeoutWorkItem = nil
        locationAuthCompletion = nil
        locationResultCompletion = nil
        locationManager?.stopUpdatingLocation()
    }

    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleDidBecomeActive() {
        lifecycleExtension?.onHostEvent(state: "resumed")
    }

    @objc private func handleWillResignActive() {
        lifecycleExtension?.onHostEvent(state: "paused")
    }

    @objc private func handleWillEnterForeground() {
        lifecycleExtension?.onHostEvent(state: "started")
    }

    @objc private func handleDidEnterBackground() {
        lifecycleExtension?.onHostEvent(state: "stopped")
    }

    private func topViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        let completion = imagePickCompletion
        imagePickCompletion = nil
        picker.dismiss(animated: true) {
            completion?(.failure(BridgeError(code: "E_INTERNAL", message: "launch canceled")))  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let imageUrl = (info[.imageURL] as? URL)?.absoluteString
            ?? "ios://picked/\(UUID().uuidString).jpg"
        let completion = imagePickCompletion
        imagePickCompletion = nil
        picker.dismiss(animated: true) {
            completion?(.success(imageUrl))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let callback = locationAuthCompletion
        locationAuthCompletion = nil
        callback?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        let callback = locationAuthCompletion
        locationAuthCompletion = nil
        callback?(status)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let callback = locationResultCompletion
        locationResultCompletion = nil
        callback?(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let callback = locationResultCompletion
        locationResultCompletion = nil
        callback?(.failure(BridgeError(code: "E_LOCATION_UNAVAILABLE", message: error.localizedDescription)))
    }
}

private final class WebViewPageContextProvider: PageContextProvider {
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext {
        TrustedPageContext(origin: normalizeOrigin(webView?.url), pageInstanceId: pageInstanceId)
    }

    private func normalizeOrigin(_ url: URL?) -> String {
        // about: 为示例层语义（WebView 空白页），保留原有映射；
        // 其余交给核心 OriginNormalizer（docs/03 §9 细则 5）：
        // file → "file://"；host 类 origin 小写 + 默认端口省略、非默认保留；
        // URL 缺失 → ""（fail-closed，不再用 "about:blank" 占位）。
        if url?.scheme?.lowercased() == "about" {
            return "about:blank"
        }
        return OriginNormalizer.normalize(url)
    }
}

private extension Result where Success == JSONValue?, Failure == BridgeError {
    /// 宿主的 Result 风格实现 → SimpleHandler 的单帧结果
    var asHandlerResult: BridgeHandlerResult {
        switch self {
        case .success(let value):
            return .success(value)
        case .failure(let error):
            return .failure(error)
        }
    }
}

private extension JSONValue {
    var asObject: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var asString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var asDouble: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}
