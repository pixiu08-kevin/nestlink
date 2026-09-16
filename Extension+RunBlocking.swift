import Foundation

/// 把 async 工作阻塞式地跑完，用于跨越 Go → Swift 的同步回调边界。
///
/// 为什么必须这样做：libbox 从 Go 侧回调 Swift 的 `openTun` 等方法是**同步**的，
/// 而 NetworkExtension 对应的 API（如 `setTunnelNetworkSettings`）是 async 的。
/// Go 的调用发生在自己创建的线程上（不是主线程），所以这里用信号量等待是安全的。
///
/// 注意：不要在 @MainActor 上下文里调用它，否则会死锁。
func runBlocking<T>(
    _ block: @escaping () async throws -> T,
    timeout: DispatchTimeInterval = .seconds(20)
) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        do {
            box.result = .success(try await block())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }

    // 必须带超时。`openTun` 是 Go 侧**同步**回调，一旦这里永久阻塞，
    // Go 线程会一直卡住 → 内核启动挂起 → 系统约 30 秒后杀掉扩展，
    // 而用户只看到「连接失败」，没有任何可诊断信息。
    //
    // 注意：超时无法中止那个 Task（NetworkExtension 的异步 API 不可取消），
    // 但能让调用方尽快失败退出并把原因上报出来。
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw ExtensionPlatformError("异步操作超时（\(timeout)）：NetworkExtension 未响应")
    }
    guard let result = box.result else {
        throw ExtensionPlatformError("异步操作既没有结果也没有错误")
    }
    return try result.get()
}

/// 因为 Result 要在 Task 与等待线程之间传递，用一个引用盒子承载。
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// 扩展内部使用的统一错误类型。
struct ExtensionPlatformError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// libbox 的日志级别。
///
/// ⚠️ 数值必须与 sing-box `log/level.go` 的 iota 顺序一致 —— 那是**从严重到不严重**：
///
///     LevelPanic = 0, LevelFatal = 1, LevelError = 2, LevelWarn = 3,
///     LevelInfo  = 4, LevelDebug = 5, LevelTrace = 6
///
/// 之前写成「trace 在前、fatal 在后」是**完全反的**（只有 warn=3 巧合正确）：
/// 传给 `commandServer.writeMessage(level:)` 后，扩展的报错会被当成 INFO，
/// 而默认的 error 会被当成 INFO —— 排障信息全部失真。
///
/// 注意 `osLogType` 走的是 enum case 而不是 rawValue，所以 Xcode 控制台里是**对的**，
/// 这让错误更隐蔽。
enum LibboxLogLevel: Int32 {
    case panic = 0
    case fatal = 1
    case error = 2
    case warn = 3
    case info = 4
    case debug = 5
    case trace = 6
}
