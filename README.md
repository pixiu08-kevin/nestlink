# Nestlink — GPL 对应源码（Corresponding Source）

本仓库提供 **Nestlink iOS 客户端**中所使用的 GPL-3.0-or-later 组件的完整对应源码，
以履行 GPL-3.0 第 6 条规定的源码提供义务。

> **This repository contains the Corresponding Source for the GPL-licensed
> components used by the Nestlink iOS app. It is not the full app.**

---

## 一、这里有什么

```
build-libbox.sh                从 sing-box 官方源码编译 Libbox.xcframework 的脚本
PacketTunnel/
  PacketTunnelProvider.swift       Packet Tunnel 扩展入口（NetworkExtension）
  ExtensionPlatformInterface.swift libbox 平台接口实现（TUN / DNS / 网络路径）
  Extension+RunBlocking.swift      libbox 同步回调桥接
LICENSE                         GPL-3.0 完整许可正文
NOTICE.md                       第三方组件、版本、版权与署名
```

### 网络内核

`Libbox.xcframework` 由 **未修改的** sing-box 官方源码编译而成：

| 项 | 值 |
|---|---|
| 上游项目 | https://github.com/SagerNet/sing-box |
| 版本 | **`v1.14.0`**（tag，未打任何补丁） |
| 构建工具 | `github.com/sagernet/gomobile` **`v0.1.12`** 的 `gobind` / `gomobile` |
| 构建命令 | `go run ./cmd/internal/build_libbox -target apple -platform ios,iossimulator` |
| 版权 | Copyright (C) 2022 by nekohasekai `<contact-sagernet@sekai.icu>` |
| 许可 | GPL-3.0-or-later（含一条附加的名称使用限制，见 `NOTICE.md`） |

**重建方式**：克隆 sing-box 官方仓库，checkout 到 `v1.14.0`，执行 `./build-libbox.sh` 即可
得到与 App 中完全一致的 `Libbox.xcframework`。因为内核源码未作任何修改，
上游仓库本身即为该组件的对应源码。

### 参考实现

`PacketTunnel/ExtensionPlatformInterface.swift` 在**结构上**参考了
https://github.com/SagerNet/sing-box-for-apple （同为 GPL-3.0-or-later），
但已按 `Libbox.xcframework` **v1.14.0** 实际生成的 `Libbox.objc.h` 接口契约重写。

它与上游 HEAD（对应 sing-box alpha 分支）存在实质差异，例如：

| 上游 HEAD（alpha） | 本实现（v1.14.0 实际契约） |
|---|---|
| `send(_:)` | `sendNotification(_:)` |
| `usePlatformAutoDetectControl()` | `usePlatformAutoDetectInterfaceControl()` |
| `PlatformInterface` 上有 `writeLog` | 没有，日志走 CommandServer |
| `updateNetworkPath(_:)` | 监听器只有 `updateDefaultInterface` |
| `usePlatformAutoRedirect()` 等 | 协议里根本不存在 |

按 GPL-3.0 第 5(a) 条，此处声明：**这些文件已被修改**，
修改日期与每次改动的记录见 App 主仓库的提交历史。

---

## 二、这里**没有**什么（以及为什么）

本仓库**不包含** Nestlink 客户端自有的应用代码：

```
ProxyClient/     SwiftUI 界面、自绘节点地图、内核命令通道、诊断层
Account/         账号体系、App Store 内购、服务端交易校验
Shared/          仅在 GPL 组件与本应用之间传递数据的桥接代码
```

这些是本应用的**独立作品**，不是 sing-box 或其参考实现的派生部分，因此不在
GPL-3.0 的覆盖范围内。

### 关于 GPL-3.0 源码提供义务的范围

GPL-3.0 第 6 条要求向**收到二进制的人**提供 GPL 覆盖部分的对应源码。
本仓库与该义务的对应关系如下：

| GPL 覆盖的部分 | 对应源码位置 |
|---|---|
| sing-box v1.14.0 内核 | 上游 https://github.com/SagerNet/sing-box 的 `v1.14.0` tag |
| `Libbox.xcframework` 构建方式 | 本仓库 `build-libbox.sh` |
| Packet Tunnel 扩展中派生自 sing-box-for-apple 的文件 | 本仓库 `PacketTunnel/` |

---

## 三、名称使用限制（重要）

sing-box 的 LICENSE 在 GPL-3.0 之外附加了一条约束：

> In addition, no derivative work may use the name or imply association
> with this application without prior consent.

因此：

- ❌ **不得**以 `sing-box`、`SingBox`、`SFI`、`SFM` 作为 App 名称或主要标识
- ❌ **不得**在描述、宣传文案或图标中暗示与 sing-box 官方存在关联、赞助或背书
- ❌ **不得**使用 sing-box 官方图标或近似图标
- ✅ **可以**以客观陈述方式说明"本 App 使用 sing-box 作为网络内核"并附上游链接

> 本仓库中的 `PacketTunnel/` 文件为**功能性代码**：其中的 TUN 参数、DNS 设置、
> 路由排除项等写法由 `libbox` 的 C 接口与 Apple 的 NetworkExtension API 决定，
> 不同实现之间必然相似。这属于接口约束下的常规写法，不构成本仓库与上游之间的额外关联。

---

## 四、许可

本仓库内容以 **GPL-3.0-or-later** 发布，完整正文见 [`LICENSE`](LICENSE)。

第三方组件、版本与版权署名见 [`NOTICE.md`](NOTICE.md)。

Nestlink 名称、标识与视觉设计不属于本许可范围。
