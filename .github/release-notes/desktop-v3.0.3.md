# 开物Praxis Desktop 3.0.3

修复 macOS Intel 首次进入时随包 Node 在 Hardened Runtime 下崩溃，导致「插件依赖更新失败 / 无法进入」。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- macOS 随包 Node 签名 entitlement 补上 `allow-unsigned-executable-memory`：Intel 上 V8 需要该权限才能 `mprotect` 可执行内存；此前仅有 `allow-jit`，Apple Silicon 可进、Intel 必崩（`Check failed: 12 == (*__error())`）。
- 版本号推进到 `3.0.3`；其余个人默认能力与 `3.0.2` 一致。

## 验证

- 源码侧增加 Node runtime entitlement 单测，要求发行签名清单包含上述权限。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收；Intel 请以本机首次进入与插件依赖更新为准。

## 下载与升级

- Windows x64：`kaiwu-3.0.3-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.3-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.3-x64.dmg`（本修复重点）。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

升级前请备份本地配置和数据。若 Intel 机仍出现「插件依赖更新失败」且日志含 `Check failed: 12`，请确认安装的是本版 `x64.dmg` 后再试。
