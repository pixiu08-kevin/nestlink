# 第三方组件与署名 (NOTICE)

本 App 包含以 **GPL-3.0-or-later** 授权的组件，其中 **sing-box** 的 `v1.14.0`
版本被静态链接为网络内核。以下署名与约束是分发本 App 时的**法律义务**，不是可选项。

> GPL 组件的完整对应源码见本仓库（`PacketTunnel/` + `build-libbox.sh`），
> 内核源码本身使用上游 `v1.14.0`，未作任何修改。
>
> 仓库地址：https://github.com/pixiu08-kevin/nestlink

---

## 1. sing-box

- 项目：https://github.com/SagerNet/sing-box
- 版本：`v1.14.0`（本项目的 `scripts/build-libbox.sh` 固定此版本）
- 许可证：GPL-3.0-or-later
- 版权：Copyright (C) 2022 by nekohasekai `<contact-sagernet@sekai.icu>`
- 使用方式：以 `Libbox.xcframework` 形式静态链接入 PacketTunnel 扩展

### 名称使用限制（重要）

sing-box 的 LICENSE 在 GPL-3.0 之外附加了一条约束：

> In addition, no derivative work may use the name or imply association
> with this application without prior consent.

因此本项目**不得**：

- 以 `sing-box`、`SingBox`、`SFI`、`SFM` 等名称作为 App 名称或主要标识；
- 在 App 描述、宣传文案或图标中暗示与 sing-box 官方存在关联、赞助或背书关系；
- 使用 sing-box 官方图标或近似图标。

可以在"关于"页面中以客观陈述方式说明"本 App 使用 sing-box 作为网络内核"，
并附上上游链接——这是署名，不是暗示关联。

**当前 `Nestlink` 是占位名，改名时请遵守以上约束。**

---

## 2. 参考实现

- 项目：https://github.com/SagerNet/sing-box-for-apple
- 许可证：GPL-3.0-or-later（与 sing-box 一致）
- 使用方式：**仅作为集成方式的参考**阅读，用于确认 NetworkExtension、
  App Group、libbox 命令服务端等接口的正确用法。

本项目中的以下文件在结构上参考了该项目，并做了裁剪（移除 macOS/tvOS/
越狱/小组件/代码编辑器等分支）：

- `PacketTunnel/PacketTunnelProvider.swift`
- `PacketTunnel/ExtensionPlatformInterface.swift`

按 GPL-3.0 要求，这些文件同样以 GPL-3.0-or-later 发布，并保留原始版权署名。

---

## 3. Go 依赖

`Libbox.xcframework` 内静态链接了大量 Go 模块（gvisor、quic-go、wireguard-go、
tailscale、utls 等），完整清单与各自许可证见：

- `sing-box` 仓库的 `go.mod` / `go.sum`
- 各模块自身的 LICENSE 文件

如需在 App 内提供"开源许可"页面，建议运行时由 sing-box 的
`libbox` 接口读取（或从 `go.sum` 生成清单），不要手工维护。

---


## 5. 分发方式合规提示

GPL-3.0 与 App Store 存在**已知的条款冲突**（Apple 的 DRM 与再分发限制
同 GPL-3.0 "不得附加额外限制"的要求相抵触）。上游 sing-box 官方 App 同样
处于这一灰色地带。

本项目按 GPL-3.0 发布并提供完整源码。你需要在以下方面自行判断：

1. 上架时在 App 描述或"关于"页面提供**源码获取地址**；
2. 不要把源码获取做成需要额外许可的形式；
3. 若未来需要闭源商业分发，必须替换内核（例如改用 MPL-2.0 的 Xray-core），
   而不是继续使用 GPL-3.0 的 libbox。

以上为工程记录，不构成法律意见；正式商用前建议咨询律师。
