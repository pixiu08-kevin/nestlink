import Foundation
import Libbox
import NetworkExtension
import os

/// 隧道扩展入口。NSExtensionPrincipalClass 在 Info.plist 里指向
/// `$(PRODUCT_MODULE_NAME).PacketTunnelProvider`。
///
/// 启动序列（必须保持这个顺序，这是 libbox 的约定）：
///
///   1. `LibboxSetup(options)`         —— 设定基础/工作/临时目录，初始化 Go 运行时
///   2. `LibboxPromoteOOMDraft()`      —— 确认内存看门狗配置
///   3. `LibboxNewCommandServer(...)`  —— 创建命令服务（App 侧据此读日志/流量）
///   4. `commandServer.start()`        —— 启动本地命令通道
///   5. `startOrReloadService(config)` —— 真正拉起 sing-box 内核
///
/// 其中第 5 步会回调 `ExtensionPlatformInterface.openTun`，由它建立
/// NEPacketTunnelNetworkSettings 并把 TUN fd 交回 Go 侧。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = Logger(subsystem: "REPLACE-ME.bundle-id", category: "PacketTunnelProvider")

    private var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    private var configContent: String?

    override init() {
        // 崩溃信号处理必须在 super.init() 之前装好，否则内核早期崩溃抓不到栈
        LibboxPrepareCrashSignalHandlers()
        // 必须**紧接**在 Prepare 之后调用（头文件原文：call this after PLCrashReporter
        // has been installed）。Reinstall 会把当前已装的信号处理器当作"崩溃上报器的处理器"
        // 记录下来；中间插入任何代码都可能装进别的处理器，崩溃时被误调用。
        // 该调用是全局函数，不涉及 self，可以安全地放在 super.init() 之前。
        LibboxReinstallCrashSignalHandlers()
        super.init()
    }

    // MARK: - 隧道生命周期

    /// 包一层只为一件事：**把失败原因落盘**。
    ///
    /// NetworkExtension 不会把这里抛出的错误交给容器 App，App 只能看到「已断开」。
    /// 详见 `ExtensionErrorRelay` 的说明。
    override func startTunnel(options: [String: NSObject]?) async throws {
        do {
            try await performStartTunnel(options: options)
            ExtensionErrorRelay.clear()
        } catch {
            ExtensionErrorRelay.write(error.localizedDescription)
            throw error
        }
    }

    private func performStartTunnel(options: [String: NSObject]?) async throws {
        // App Group 是 App 与扩展协作的前提（命令通道的 socket、落盘配置都在里面）。
        // 拿不到就直接失败——不要回退到 per-process 临时目录：
        // 那样两边路径不一致，隧道表面能连上，但命令通道全废、系统重启隧道也读不到配置，
        // 故障会伪装成"连接正常"，比直接报错难查得多。
        guard AppConfiguration.sharedDirectoryStrict != nil else {
            throw ExtensionPlatformError(
                "App Group \(AppConfiguration.appGroupIdentifier) 不可用。请检查 entitlements 与签名配置。"
            )
        }

        let content = try resolveConfigContent(options)
        configContent = content

        // 配置同时落盘，供系统在 options 为空时重启隧道使用
        do {
            try content.write(to: AppConfiguration.configFileURL, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("写入共享配置失败: \(error.localizedDescription, privacy: .public)")
        }

        try setupLibbox()

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError) else {
            throw ExtensionPlatformError(
                "(packet-tunnel) 创建命令服务失败: \(serverError?.localizedDescription ?? "未知原因")"
            )
        }
        commandServer = server
        try server.start()

        // App 与扩展必须用同一份共享目录：两边路径差一个字符，socket 就连不上。
        let extensionBasePath = AppConfiguration.sharedDirectory.path
        ExtensionDiagnostics.write(
            basePath: extensionBasePath,
            socketPath: extensionBasePath + "/command.sock",  // 内核命令通道，路径名保持中性
            socketExists: FileManager.default.fileExists(atPath: extensionBasePath + "/command.sock")
        )

        do {
            try server.startOrReloadService(content, options: LibboxOverrideOptions())
        } catch {
            // 必须清理：否则 commandServer 仍非 nil 且已 start()，
            // 下次重试会再建一个 —— 旧的不释放，且两个 server 争同一个 socket 文件
            server.close()
            commandServer = nil
            throw ExtensionPlatformError("(packet-tunnel) 启动内核失败: \(error.localizedDescription)")
        }

        writeMessage("sing-box 内核已启动", level: .info)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("正在停止隧道，reason=\(reason.rawValue)", level: .info)
        stopService()
        if let server = commandServer {
            // 给内核一点时间把日志刷完，再关闭命令服务
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    /// App 通过 `NETunnelProviderSession.sendProviderMessage` 发消息时触发，
    /// 用于在不重启隧道的情况下热更新配置。
    /// 配置重载是否正在进行。
    /// 两条消息并发到达会触发两次并发 `startOrReloadService`，
    /// 进而可能并发 `openTun` / `setTunnelNetworkSettings`。
    private var isReloading = false

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard !isReloading else {
            return "上一次配置重载尚未完成，请稍候".data(using: .utf8)
        }
        isReloading = true
        defer { isReloading = false }
        do {
            let options = try JSONSerialization.jsonObject(with: messageData) as? [String: NSObject]
            guard let content = options?[AppConfiguration.configContentKey] as? String else {
                return "消息里缺少 configContent".data(using: .utf8)
            }
            configContent = content
            try content.write(to: AppConfiguration.configFileURL, atomically: true, encoding: .utf8)
            try await reloadService()
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    // MARK: - 供 platformInterface 调用

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("停止内核失败: \(error.localizedDescription)", level: .error)
        }
        platformInterface.reset()
    }

    func reloadService() async throws {
        guard let configContent else {
            throw ExtensionPlatformError("没有可用的配置，无法重载")
        }
        writeMessage("正在重载配置", level: .info)
        reasserting = true
        defer { reasserting = false }
        try commandServer?.startOrReloadService(configContent, options: LibboxOverrideOptions())
    }

    func writeMessage(_ message: String, level: LibboxLogLevel = .error) {
        Self.logger.log(level: level.osLogType, "\(message, privacy: .public)")
        commandServer?.writeMessage(level.rawValue, message: message)
    }

    // MARK: - 内部

    private func setupLibbox() throws {
        let options = LibboxSetupOptions()
        options.basePath = AppConfiguration.sharedDirectory.path
        options.workingPath = AppConfiguration.workingDirectory.path
        options.tempPath = AppConfiguration.cacheDirectory.path
        options.logMaxLines = 3000
        options.debug = false
        options.crashReportSource = "NetworkExtension"
        options.appVersion = Self.bundleValue("CFBundleVersion")
        options.appMarketingVersion = Self.bundleValue("CFBundleShortVersionString")
        // iOS 上常驻内存受限，开启内存看门狗
        options.oomKillerEnabled = true

        var setupError: NSError?
        let ok = LibboxSetup(options, &setupError)
        if !ok || setupError != nil {
            throw ExtensionPlatformError(
                "(packet-tunnel) 初始化失败: \(setupError?.localizedDescription ?? "未知原因")"
            )
        }
        LibboxPromoteOOMDraft()
        // v1.14.0 只有 Promote，没有 Discard（上游 alpha 才有）
        LibboxPromotePowerReportDraft()
    }

    private func resolveConfigContent(_ options: [String: NSObject]?) throws -> String {
        if let content = options?[AppConfiguration.configContentKey] as? String, !content.isEmpty {
            return content
        }
        // 系统自行重启隧道时不会传 options，此时用 App 落盘的配置兜底
        let url = AppConfiguration.configFileURL
        if let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
            Self.logger.info("options 为空，已从 App Group 读取落盘配置")
            return content
        }
        throw ExtensionPlatformError("缺少配置：options 与 App Group 共享配置都为空")
    }

    private static func bundleValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}

private extension LibboxLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .panic: return .fault
        case .fatal, .error: return .error
        case .warn: return .default
        case .info: return .info
        case .debug, .trace: return .debug
        }
    }
}
