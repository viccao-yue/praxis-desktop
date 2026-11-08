# 开物Praxis Desktop 3.0.0

本版结束 Desktop 的 alpha 版本号，安装包与发布说明不再带 `alpha.x` 字样。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- Agent 预设「自定义」只保留每个数字员工当前已发布的那一份，数量与数字员工目录对齐；重新发布后旧预设退出官方名册。
- 承接此前 Profile 依赖物化修复：`proper-lockfile` 继续使用 `signal-exit` 3.x，避免打包后 Host 因 `onExit is not a function` 启动失败。
- 六个默认数字员工使用同一套现代 3D 图标。

## 验证

- 源码侧覆盖专家预设名册单测：冷启动与再次发布后，Agent 预设名册不超过「默认数字员工 + 当前个人已发布」数量。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

升级前请备份本地配置和数据。
