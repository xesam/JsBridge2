import Foundation
import XCTest
@testable import BridgeCore

/// 共享测试基建（对齐 Android 参考实现的 BridgeTestSupport）：
/// 此前 ConformanceCoreBaselineTests / BindTransportTests / UnifiedAPITests
/// 各自维护近重复的 fake transport 与 requestJson 手写 JSON 助手，本文收敛为单一实现：
/// - `FakeBridgeTransport`：三处私有 Mock/Fake transport 的超集
/// - `requestJson`：request 信封 JSON 构造助手
/// - `PreconditionProbe`：precondition trap 的子进程探针（Swift 的 precondition 是
///   进程级 trap，XCTest 无法在进程内断言，须以子进程观测）

// MARK: - Fake Transport（超集）

/// 三处私有 Mock/Fake transport 的并集：记录全部 send 投递，支持经 bind 回调
/// 模拟入站消息。sendEnabled 关闭后 send 返回 false（send 失败路径断言用）。
final class FakeBridgeTransport: BridgeTransport {
    var sendEnabled: Bool = true
    private(set) var sentMessages: [String] = []
    private var bindHandler: ((String) -> Void)?

    func bind(listener: @escaping (String) -> Void) {
        bindHandler = listener
    }

    @discardableResult
    func send(_ messageJson: String) -> Bool {
        sentMessages.append(messageJson)
        return sendEnabled
    }

    func close() {
        bindHandler = nil
    }

    /// 模拟 JS 入站消息：经 bind 回调闭环送达（对齐 Android FakeBridgeTransport.deliver）。
    func simulateIncoming(_ messageJson: String) {
        bindHandler?(messageJson)
    }

    func clearSentMessages() {
        sentMessages.removeAll()
    }

    /// 返回所有 reqId 匹配的响应帧（流式多帧断言用）。
    func framesForReqId(_ requestId: String) -> [BridgeMessage] {
        sentMessages.compactMap { json in
            guard let data = json.data(using: .utf8),
                  let message = try? JSONDecoder().decode(BridgeMessage.self, from: data),
                  message.reqId == requestId
            else { return nil }
            return message
        }
    }
}

// MARK: - request JSON 助手

/// 手写 request 信封 JSON 助手（原先在 ConformanceCoreBaselineTests 与
/// BindTransportTests 中整段重复）。`keep` 为流式请求标志（C13 等用例）。
func requestJson(
    id: String,
    method: String,
    sessionId: String,
    payload: [String: Any],
    keep: Bool = false
) -> String {
    let request: [String: Any] = [
        "id": id,
        "sessionId": sessionId,
        "kind": "request",
        "method": method,
        "ts": Int(Date().timeIntervalSince1970 * 1000),
        "timeoutMs": 10000,
        "keep": keep,
        "payload": payload,
        "reqId": NSNull(),
        "done": NSNull(),
        "ok": NSNull(),
        "error": NSNull()
    ]
    let data = try! JSONSerialization.data(withJSONObject: request, options: [])
    return String(data: data, encoding: .utf8)!
}

// MARK: - 响应解析助手

/// JSON 字符串 → 字典（原 ConformanceCoreBaselineTests 的私有 object(from:) 与
/// BindTransportTests 的 parseJson 各持一份同形实现，收敛至此）。
func object(from jsonString: String?) -> [String: Any]? {
    guard
        let jsonString,
        let data = jsonString.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data, options: []),
        let dict = obj as? [String: Any]
    else {
        return nil
    }
    return dict
}

/// 响应帧 error.code；无 error 时返回 ""。
func errorCode(from jsonString: String?) -> String {
    let json = object(from: jsonString)
    let error = json?["error"] as? [String: Any]
    return (error?["code"] as? String) ?? ""
}

// MARK: - precondition 子进程探针

/// `JsBridge.init` 的 SecurityConfig nil 校验以 `precondition` 实现——它是进程级 trap，
/// XCTest 无法在进程内捕获。探针机制：父进程用 xctest 以子进程重跑当前测试 bundle 的
/// **单条**探针测试；子进程带 `JSBRIDGE_PRECONDITION_PROBE` 环境变量命中对应分支，
/// 故意执行应触发 precondition 的构造——
/// - 子进程死于非捕获信号（trap）→ 校验存在，父进程断言通过
/// - 探针存活并以 exit(42) 落地 → 未触发 precondition，父进程断言失败
enum PreconditionProbe {
    private static let probeEnvironmentKey = "JSBRIDGE_PRECONDITION_PROBE"
    /// 探针存活退出码：构造未触发 precondition 时子进程以此码落地。
    private static let probeSurvivalExitCode: Int32 = 42

    /// 当前进程是否处于探针子进程模式；命中时返回探针名。
    static func currentProbe() -> String? {
        ProcessInfo.processInfo.environment[probeEnvironmentKey]
    }

    /// 仅在探针子进程内调用：构造存活（未触发 precondition）时以此码落地，
    /// 让父进程得以区分"无校验"与"trap"。
    static func probeSurvived() -> Never {
        exit(probeSurvivalExitCode)
    }

    /// 父进程侧：以子进程运行单条探针测试，断言其死于 precondition trap。
    /// - Parameters:
    ///   - probe: 探针名（写入子进程环境变量，供子进程侧分支匹配）
    ///   - testCase: 单条测试选择器，形如 "ClassName/testMethod"
    ///   - bundle: 当前测试 bundle（子进程以同一 bundle 重跑该测试）
    static func expectTrap(
        probe: String,
        testCase: String,
        bundle: Bundle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let xctestPath = locateXCTest(file: file, line: line) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xctestPath)
        process.arguments = ["-XCTest", testCase, bundle.bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[probeEnvironmentKey] = probe
        process.environment = environment
        // 丢弃子进程输出，避免污染父进程测试日志（nullDevice 不占缓冲，不会写阻塞）
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            XCTFail("precondition probe subprocess failed to launch: \(error)", file: file, line: line)
            return
        }
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            return // 子进程死于 trap：precondition 校验存在
        }
        if process.terminationStatus == probeSurvivalExitCode {
            XCTFail(
                "expected precondition trap for probe '\(probe)', but init survived",
                file: file, line: line
            )
            return
        }
        XCTFail(
            "precondition probe '\(probe)' exited unexpectedly: status \(process.terminationStatus) "
                + "(reason \(process.terminationReason.rawValue))",
            file: file, line: line
        )
    }

    /// 定位 xctest 可执行文件（/usr/bin/xctest 已随 macOS 移除）。
    /// 解析含一次 `xcrun` 子进程调用——记忆化，全 suite 只解析一次。
    // 测试串行执行、单一写入点——跨并发域记忆化以 nonisolated(unsafe) 显式豁免数据竞争检查
    private nonisolated(unsafe) static var memoizedXCTestPath: String?

    private static func locateXCTest(file: StaticString, line: UInt) -> String? {
        if let memoized = memoizedXCTestPath {
            return memoized
        }
        // 首选 xcrun（尊重 DEVELOPER_DIR 定制），失败时回退已知路径
        let fallbacks = [
            "/usr/bin/xctest",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
        ]
        let resolved = runTool("/usr/bin/xcrun", ["--find", "xctest"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [resolved].compactMap { $0 } + fallbacks
        for path in candidates
        where (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
            memoizedXCTestPath = path
            return path
        }
        XCTFail(
            "precondition probe requires the 'xctest' tool: neither `xcrun --find xctest` "
                + "nor fallback paths resolved to an existing file",
            file: file, line: line
        )
        return nil
    }

    private static func runTool(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // 丢弃 stderr（xcrun 失败提示无关断言）；须在 run() 前装配
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
