# 开物Praxis Desktop 3.0.0-alpha.12

本次修复打包时准备开物 Profile 会因互相依赖的私有包无限嵌套而失败的问题。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- Profile 根依赖物化时，沿当前依赖链再次遇到同一包即停止，避免互相依赖把嵌套路径拉到超长后失败；各包仍保留各自选中的依赖版本（例如 `signal-exit` 3.x 与 4.x）。
- 默认数字员工顺序：常青云产品顾问、常青云报销顾问、常青云容器运维顾问，其余顺延；个人区与企业区同一清单。

## 验证

- 源码侧覆盖 Profile 模块物化单测与专家目录播种顺序校验。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.12-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.12-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.12-x64.dmg`。
- 企业连接另提供独立 `workdsh-enterprise-connection` 归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。

开源上游参考：[github.com/techflag/workdsh](https://github.com/techflag/workdsh)
