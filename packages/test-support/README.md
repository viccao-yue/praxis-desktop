# 测试辅助

状态：**已实现**。为 DSH `0.2.2+` 的 batch-only `tools.execute` 提供单次调用适配，供集成测试与探针复用。

- 职责：把一次嵌套工具调用转成官方 batch API，并返回首个结果。
- 边界：仅测试与探针使用；产品 Host/Client 路径自行使用 batch `tools.execute`，不依赖本包。

## 开发前阅读

[规则](../../apps/web/AGENTS.md)、[契约](../../apps/web/docs/CONTRACTS.md)。
