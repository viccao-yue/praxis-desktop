# 开物Praxis Desktop 3.0.0-alpha.14

本次让 Profile 根上已有的依赖不再被重复嵌套，同时给版本不同的私有包补上它自己的下一层依赖。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- `dsh-remotion` 下的 `proper-lockfile` 继续使用 `signal-exit` 3.x 的函数导出，避免打包后的 Host 因 `onExit is not a function` 启动失败。
- 与 Profile 根所选版本相同的包不再复制到导入方下面；只有版本不同的依赖才保留私有副本，并且最多再带一层它自己的不同版本依赖。
- 六个默认数字员工头像改为同一套现代 3D 图标。

## 验证

- 源码侧覆盖 Profile 模块物化单测：根上已有的包不重复嵌套，私有旧版本仍带上自己的 `signal-exit` 3.x，且不再继续向下复制。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.14-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.14-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.14-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。
