import Foundation
import Libbox
// Network 必须显式导入：NWPath 在 Network 与 NetworkExtension 中同名，
// 只导入 NetworkExtension 时 Swift 会选错那一个（它没有 availableInterfaces）。
import Network
import NetworkExtension
import os
import UserNotifications

/// libbox 的平台接口实现。
///
/// **本文件的方法签名严格对应 `Libbox.xcframework` 里 v1.14.0 生成的
/// `Libbox.objc.h`，不是照抄上游参考仓库的 Swift。** 二者存在实质差异
/// （上游 HEAD 对应 sing-box alpha 分支），例如：
///
/// | 上游 HEAD（alpha）                  | 本文件（v1.14.0 实际契约）        |
/// |------------------------------------|----------------------------------|
/// | `send(_:)`                         | `sendNotification(_:)`           |
/// | `usePlatformAutoDetectControl()`   | `usePlatformAutoDetectInterfaceControl()` |
/// | PlatformInterface 上有 `writeLog`  | 没有，日志走 CommandServer        |
/// | `updateNetworkPath(_:)`            | 监听器只有 `updateDefaultInterface` |
/// | `usePlatformAutoRedirect()` 等     | 协议里根本不存在                  |
///
/// 改动此文件时请对照头文件，不要凭记忆。
final class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private static let logger = Logger(subsystem: "REPLACE-ME.bundle-id", category: "PlatformInterface")

    private let tunnel: PacketTunnelProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var nwMonitor: NWPathMonitor?

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    // MARK: - TUN

    /// 由 libbox 回调：把 sing-box 的 TUN 参数翻译成 NEPacketTunnelNetworkSettings，
    /// 然后把底层 TUN 文件描述符交回给 Go 侧。
    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw ExtensionPlatformError("openTun: options 为空")
        }
        guard let ret0_ else {
            throw ExtensionPlatformError("openTun: 返回指针为空")
        }

        // ── 开机自检：把隧道协议上的那几个路由开关打到日志里 ──
        //
        // 排查 UDP 不走隧道时，最要紧的是先确认"我们设的开关到底有没有生效"。
        // 这一层在 App 侧设、在扩展侧读，中间隔着 saveToPreferences /
        // loadFromPreferences，光看代码无法确认。
        //
        // 日志里有了这几行，就能一眼判断：
        //   · includeAllNetworks 是不是真的 true
        //   · 有没有别的开关（exclude*）把流量放了出去
        if let proto = tunnel.protocolConfiguration as? NETunnelProviderProtocol {
            Self.logger.info("""
                隧道开关: includeAllNetworks=\(proto.includeAllNetworks, privacy: .public) \
                enforceRoutes=\(proto.enforceRoutes, privacy: .public) \
                excludeLocalNetworks=\(proto.excludeLocalNetworks, privacy: .public)
                """)
            if #available(iOS 16.4, *) {
                Self.logger.info("""
                    隧道排除项: excludeAPNs=\(proto.excludeAPNs, privacy: .public) \
                    excludeCellularServices=\(proto.excludeCellularServices, privacy: .public)
                    """)
            }
        } else {
            Self.logger.error("隧道 protocolConfiguration 不是 NETunnelProviderProtocol —— 开关状态无从判断")
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if !options.getAutoRoute() {
            // auto_route=false 时下面整块（mtu / DNS / IPv4 / IPv6 / 路由）都不会执行，
            // 结果是一个"连上了却不接管任何流量"的空隧道，而**系统不会有任何提示**。
            // 配置正常应带 auto_route=true；一旦被改成 false，
            // 这是最难查的一类故障——必须留下醒目记录。
            Self.logger.error("配置里 auto_route=false：隧道不会接管流量，将建立一条空隧道。请检查 tun 配置。")
        }
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            // DNS
            var dnsSettings: NEDNSSettings?
            if let dnsMode = options.getDNSMode(), dnsMode.value != LibboxDNSModeDisabled {
                // 注意：getDNSServerAddress 带 NSError** 参数，Swift 里是 throws
                // 且返回**非可选**值（与头文件的 _Nullable 标注不一致）。
                let iterator = try options.getDNSServerAddress()
                var servers: [String] = []
                while iterator.hasNext() {
                    servers.append(iterator.next())
                }
                if !servers.isEmpty {
                    let created = NEDNSSettings(servers: servers)
                    settings.dnsSettings = created
                    dnsSettings = created
                }
            }

            // IPv4
            var ipv4Addresses: [String] = []
            var ipv4Masks: [String] = []
            if let iterator = options.getInet4Address() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv4Addresses.append(prefix.address())
                    ipv4Masks.append(prefix.mask())
                }
            }
            if !ipv4Addresses.isEmpty {
                let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)

                var included: [NEIPv4Route] = []
                if let iterator = options.getInet4RouteAddress(), iterator.hasNext() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        included.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                    }
                } else {
                    // 未显式给出时按“默认路由”处理，让全部流量进入隧道
                    included.append(NEIPv4Route.default())
                }

                var excluded: [NEIPv4Route] = []
                if let iterator = options.getInet4RouteExcludeAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        excluded.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                    }
                }

                ipv4Settings.includedRoutes = included
                ipv4Settings.excludedRoutes = excluded
                settings.ipv4Settings = ipv4Settings
            }

            // 分流模式（没有默认路由）下必须让 DNS 也走隧道：
            // 否则系统仍用本地 DNS 解析，分流规则里的域名会解析到错误结果，
            // 表现为“规则没生效”。这是必须保留的处理。
            let hasDefaultRoute = (settings.ipv4Settings?.includedRoutes ?? []).contains {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            }
            if !hasDefaultRoute {
                dnsSettings?.matchDomains = [""]
                dnsSettings?.matchDomainsNoSearch = true
            }

            // IPv6
            var ipv6Addresses: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            if let iterator = options.getInet6Address() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv6Addresses.append(prefix.address())
                    ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
                }
            }
            if !ipv6Addresses.isEmpty {
                let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)

                var included: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteAddress(), iterator.hasNext() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        included.append(NEIPv6Route(
                            destinationAddress: prefix.address(),
                            networkPrefixLength: NSNumber(value: prefix.prefix())
                        ))
                    }
                } else {
                    included.append(NEIPv6Route.default())
                }

                var excluded: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteExcludeAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        excluded.append(NEIPv6Route(
                            destinationAddress: prefix.address(),
                            networkPrefixLength: NSNumber(value: prefix.prefix())
                        ))
                    }
                }

                ipv6Settings.includedRoutes = included
                ipv6Settings.excludedRoutes = excluded
                settings.ipv6Settings = ipv6Settings
            }
        }

        // HTTP 代理入站（sing-box 配置里写了 http proxy inbound 时）
        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let server = NEProxyServer(
                address: options.getHTTPProxyServer(),
                port: Int(options.getHTTPProxyServerPort())
            )
            proxySettings.httpServer = server
            proxySettings.httpsServer = server
            proxySettings.httpEnabled = true
            proxySettings.httpsEnabled = true

            if let iterator = options.getHTTPProxyBypassDomain() {
                var bypass: [String] = []
                while iterator.hasNext() {
                    bypass.append(iterator.next())
                }
                if !bypass.isEmpty {
                    proxySettings.exceptionList = bypass
                }
            }
            if let iterator = options.getHTTPProxyMatchDomain() {
                var match: [String] = []
                while iterator.hasNext() {
                    match.append(iterator.next())
                }
                if !match.isEmpty {
                    proxySettings.matchDomains = match
                }
            }
            settings.proxySettings = proxySettings
        }

        try runBlocking {
            try await self.tunnel.setTunnelNetworkSettings(settings)
        }
        // 必须在**设置成功之后**才记录。否则失败时 networkSettings 仍指向未生效的配置，
        // 后续 clearDNSCache / setSystemProxyEnabled / getSystemProxyStatus 会误判为有效。
        networkSettings = settings

        // NetworkExtension 没有公开 API 能取到 TUN 的 fd，iOS 上只能通过 KVC
        // 读该属性取得。上游官方实现（sing-box-for-apple）采用同样的方式。
        if let tunFD = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFD
            return
        }

        // 兜底：libbox 自己缓存的 fd（某些系统版本上 KVC 取不到时可用）
        let fallbackFD = LibboxGetTunnelFileDescriptor()
        if fallbackFD != -1 {
            ret0_.pointee = fallbackFD
            return
        }

        throw ExtensionPlatformError("拿不到 TUN 文件描述符：KVC 与 LibboxGetTunnelFileDescriptor 都失败")
    }

    // MARK: - 网络状态

    // 注意：Swift 侧名字是 usePlatformAutoDetectControl()，
    // 而非头文件里的 ObjC 名 usePlatformAutoDetectInterfaceControl。
    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_ fd: Int32) throws {}

    func useProcFS() -> Bool { false }

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool {
        // includeAllNetworks 是 iOS 16.4 才有的属性，工程最低版本是 16.0
        if #available(iOS 16.4, *) {
            return tunnel.protocolConfiguration.includeAllNetworks
        }
        return false
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor

        let semaphore = DispatchSemaphore(value: 0)
        // 用一次性标志代替"在回调里重写回调"——后者会让闭包捕获 monitor 自身，
        // 形成 monitor ↔ pathUpdateHandler 的循环引用，`cancel()` 也不保证释放。
        let firstUpdateTaken = FlagBox()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.updateDefaultInterface(listener, path)
            if firstUpdateTaken.take() { semaphore.signal() }
        }
        monitor.start(queue: DispatchQueue.global())

        // 等首次路径信息就绪，保证 libbox 拿到的是有效接口而非空值。
        // 但**必须有超时**：无超时会永久阻塞 Go 的调用线程。
        if semaphore.wait(timeout: .now() + .seconds(5)) != .success {
            // 不抛错：接口信息稍后仍会通过后续路径回调补上，
            // 为一个可能只是慢的环境直接让隧道起不来并不划算。
            Self.logger.error("等待默认接口超时（5s），内核可能暂时拿不到出站接口")
        }
    }

    private func updateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        guard path.status != .unsatisfied, let defaultInterface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            defaultInterface.name,
            interfaceIndex: Int32(defaultInterface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw ExtensionPlatformError("getInterfaces: 网络监视器尚未启动")
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for entry in path.availableInterfaces {
            let item = LibboxNetworkInterface()
            item.name = entry.name
            item.index = Int32(entry.index)
            switch entry.type {
            case .wifi: item.type = LibboxInterfaceTypeWIFI
            case .cellular: item.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: item.type = LibboxInterfaceTypeEthernet
            default: item.type = LibboxInterfaceTypeOther
            }
            interfaces.append(item)
        }
        return NetworkInterfaceArray(interfaces)
    }

    func clearDNSCache() {
        guard let networkSettings else { return }
        do {
            try runBlocking {
                self.tunnel.reasserting = true
                defer { self.tunnel.reasserting = false }
                try await self.tunnel.setTunnelNetworkSettings(nil)
                try await self.tunnel.setTunnelNetworkSettings(networkSettings)
            }
        } catch {
            Self.logger.error("清空 DNS 缓存失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Wi-Fi

    /// 刻意返回 nil。
    ///
    /// 读取 SSID 需要 `com.apple.developer.networking.wifi-info` 权限，而该权限
    /// 需要向 Apple 单独申请。为了让你第一次真机签名就能通过，这里不声明该权限，
    /// 因此也拿不到 SSID——**配置里基于 `wifi_ssid` 的路由规则将不会命中**。
    /// 需要时先在开发者后台申请权限，再把 entitlements 与这里一起打开。
    func readWIFIState() -> LibboxWIFIState? { nil }

    // MARK: - 通知

    // Swift 侧名字是 send(_:)，不是头文件里的 sendNotification(_:)
    func send(_ notification: LibboxNotification?) throws {
        guard let notification else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        if !notification.openURL.isEmpty {
            content.userInfo["OPEN_URL"] = notification.openURL
        }

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        try runBlocking {
            try await UNUserNotificationCenter.current().add(request)
        }
    }

    func cancelNotification(_ identifier: String?, typeID _: Int32) throws {
        guard let identifier else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    // MARK: - iOS 上不支持的能力（保持显式失败，避免静默失效）

    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32
    ) throws -> LibboxConnectionOwner {
        // 非越狱 iOS 无法查询连接属主（没有 procfs）。上游同样抛错。
        throw ExtensionPlatformError("findConnectionOwner 在非越狱 iOS 上不可用")
    }

    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }

    func registerMyInterface(_ name: String?) {}

    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}

    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws {
        throw ExtensionPlatformError("SSH 服务在 iOS 上不可用")
    }

    func openShellSession(
        _ user: LibboxPlatformUser?,
        command: String?,
        environ: LibboxStringIteratorProtocol?,
        term: String?,
        rows: Int32,
        cols: Int32
    ) throws -> LibboxShellSessionProtocol {
        throw ExtensionPlatformError("SSH 会话在 iOS 上不可用")
    }

    // 这两个方法在 Swift 里**不是 throws**，而是显式传入 NSErrorPointer。
    // 这是 gomobile 生成的重命名结果，与头文件签名看起来不同。
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = ExtensionPlatformError("SSH 在 iOS 上不可用") as NSError
        return ""
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = ExtensionPlatformError("SFTP 在 iOS 上不可用") as NSError
        return ""
    }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw ExtensionPlatformError("lookupUser 在 iOS 上不可用")
    }

    func usePlatformBridge() -> Bool { false }

    func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol {
        throw ExtensionPlatformError("bridge 在 iOS 上不可用")
    }

    func tailscaleHostname() -> String {
        // 上游用 DeviceKit 取机型名。为减少依赖，这里复用 App 自身的 bundle 名。
        "proxyclient"
    }

    // MARK: - LibboxCommandServerHandlerProtocol

    func serviceStop() throws {
        tunnel.stopService()
    }

    func serviceReload() throws {
        try runBlocking {
            try await self.tunnel.reloadService()
        }
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        guard let proxySettings = networkSettings?.proxySettings, proxySettings.httpServer != nil else {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
        guard let settings = networkSettings,
              let proxySettings = settings.proxySettings,
              proxySettings.httpServer != nil,
              proxySettings.httpEnabled != enabled
        else { return }
        proxySettings.httpEnabled = enabled
        proxySettings.httpsEnabled = enabled
        settings.proxySettings = proxySettings
        try runBlocking {
            try await self.tunnel.setTunnelNetworkSettings(settings)
        }
    }

    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw ExtensionPlatformError("SSH agent 转发在 iOS 上不可用")
    }

    func triggerNativeCrash() throws {
        // 调试用：libbox 主动触发崩溃以便验证崩溃上报链路
        // 延迟到干净线程再崩。在 Go 回调栈上直接 fatalError 会让崩溃报告
        // 缺少有效调用栈，反而失去了「制造一次真实崩溃来验证上报链路」的意义。
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
            fatalError("libbox 请求的原生崩溃")
        }
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        Self.logger.debug("\(message, privacy: .public)")
    }

    func reset() {
        networkSettings = nil
        nwMonitor?.cancel()
        nwMonitor = nil
    }
}

/// 只允许被"取走"一次的线程安全标志。
///
/// 用于「只等第一次回调，但回调本身要一直保留」的场景——
/// 用重写 `pathUpdateHandler` 的写法会让闭包捕获 monitor 自身，形成循环引用。
private final class FlagBox: @unchecked Sendable {
    private var available = true
    private let lock = NSLock()

    /// 返回 true 表示这是第一次调用
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasAvailable = available
        available = false
        return wasAvailable
    }
}

/// 把 Swift 数组适配成 libbox 需要的迭代器协议。
final class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var nextValue: LibboxNetworkInterface?

    init(_ array: [LibboxNetworkInterface]) {
        iterator = array.makeIterator()
    }

    func hasNext() -> Bool {
        nextValue = iterator.next()
        return nextValue != nil
    }

    func next() -> LibboxNetworkInterface? {
        nextValue
    }
}
