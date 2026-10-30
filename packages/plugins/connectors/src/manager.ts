import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Context, Service } from '@deepseek-ai/cordis';
import type { Agent } from '@deepseek-ai/dsh-agent';
import { credentialRef } from '@deepseek-ai/dsh-credentials';
import * as McpClient from '@deepseek-ai/dsh-mcp-client';
import type { KvTable } from '@deepseek-ai/dsh-storage-domain';
import type { ConnectorConfigView, ConnectorInput, ConnectorManagementService, ConnectorState, ConnectorSummary } from './shared.js';
import { connectorDefinitionSchema, connectorSelectionsDomainSpec, connectorsDomainSpec, type ConnectorDefinition, type ConnectorSelection } from './storage.js';

declare module '@deepseek-ai/cordis' { interface Context { workdshConnectors: ConnectorManagementService; } }

const serverPath = fileURLToPath(new URL('./example-server.mjs', import.meta.url));
/** The bundled example belongs to the running package, not its installation path. */
export function connectorProcess(definition: Pick<ConnectorDefinition, 'id' | 'serverName' | 'transport' | 'command' | 'args' | 'authorizationCredentialRef'>) {
  const bundledExample = definition.id === 'workdsh-example' && definition.serverName === 'workdsh-example'
    && definition.transport === 'stdio' && !definition.authorizationCredentialRef
    && definition.args?.length === 1 && /(?:^|[\\/])example-server\.mjs$/.test(definition.args[0]!)
    && /(?:^|[\\/])node(?:\.exe)?$/.test(definition.command ?? '');
  return bundledExample ? { command: process.execPath, args: [serverPath] }
    : { command: definition.command!, args: [...(definition.args ?? [])] };
}
type ChildFiber = { dispose(): Promise<void> };
type Runtime = { child?: ChildFiber; state: ConnectorState; diagnostic?: string };
type JsonRecord = Record<string, unknown>;
const record = (value: unknown): JsonRecord | undefined => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JsonRecord : undefined;
const idPart = (value: string) => value.replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48);
const refFor = (value: string) => credentialRef(value) as unknown as Parameters<Context['credentials']['resolve']>[0];

export interface ConnectorManagerOptions {
  seedExample?: boolean;
}

/** Persist connector instances here; delegate protocol, transport, discovery and reconnect to official MCP clients. */
export class ConnectorManager extends Service implements ConnectorManagementService {
  static inject = ['storageDomain', 'tools', 'mcpResources', 'agents', 'credentials', 'workdshSessionAccess'];
  private definitions?: KvTable<string, ConnectorDefinition>;
  private selections?: KvTable<string, ConnectorSelection>;
  private readonly runtimes = new Map<string, Runtime>();
  private readonly restrictions = new WeakMap<Agent, () => void>();
  private serial: Promise<void> = Promise.resolve();

  constructor(ctx: Context, private readonly options: ConnectorManagerOptions = {}) { super(ctx, 'workdshConnectors'); }

  async [Service.init](): Promise<void> {
    const domain = await this.ctx.storageDomain.open(connectorsDomainSpec);
    this.ctx.effect(() => () => domain.close(), 'workdshConnectors.domainClose');
    this.definitions = domain.table('definitions');
    const selectionDomain = await this.ctx.storageDomain.open(connectorSelectionsDomainSpec);
    this.ctx.effect(() => () => selectionDomain.close(), 'workdshConnectors.selectionDomainClose');
    this.selections = selectionDomain.table('selections');
    if (this.options.seedExample !== false && this.definitions.get('workdsh-example')) {
      await this.definitions.delete('workdsh-example');
      if (!domain.global.get().seededExample) await domain.global.set({ seededExample: true });
    }
    if (this.options.seedExample !== false && !this.definitions.get('windows-mcp')) {
      const now = new Date().toISOString();
      await this.definitions.put('windows-mcp', {
        id: 'windows-mcp', title: 'Windows MCP', description: '各系统都能在列表中看到。仅 Windows 10/11 可启用，用来操作本机桌面；启用前需要 Python 3.14 和 uv。默认关闭。',
        serverName: 'windows-mcp', transport: 'stdio', command: 'uvx', args: ['windows-mcp', 'serve'], enabled: false,
        createdAt: now, updatedAt: now,
      });
    }
    // Personal and enterprise Profiles share ConnectorManager; seed once per storage domain.
    if (this.options.seedExample !== false && !this.definitions.get('libtv')) {
      const now = new Date().toISOString();
      const accessKey = process.env.LIBTV_ACCESS_KEY?.trim();
      let authorizationCredentialRef: string | undefined;
      if (accessKey) {
        authorizationCredentialRef = this.credentialName('libtv');
        await this.ctx.credentials.set(
          refFor(authorizationCredentialRef),
          /^(Bearer|Basic)\s/i.test(accessKey) ? accessKey : `Bearer ${accessKey}`,
        );
      }
      await this.definitions.put('libtv', {
        id: 'libtv',
        title: 'LibTV',
        description: 'LiblibAI 远程 MCP（生图/生视频与画布创作）。默认启用；请编辑并填写访问令牌后即可在会话中选择。',
        serverName: 'libtv',
        transport: 'streamable-http',
        url: 'https://mcp.liblib.tv/mcp',
        ...(authorizationCredentialRef ? { authorizationCredentialRef } : {}),
        enabled: true,
        createdAt: now,
        updatedAt: now,
      });
    } else if (this.options.seedExample !== false) {
      // Keep product default: LibTV stays enabled even on older seeds that shipped disabled.
      const current = this.definitions.get('libtv');
      if (current && !current.enabled) {
        await this.definitions.put('libtv', { ...current, enabled: true, updatedAt: new Date().toISOString() });
      }
    }
    for (const [, definition] of this.table().entries()) {
      const blocked = this.windowsOnlyBlocked(definition);
      this.runtimes.set(definition.id, { state: definition.enabled && !blocked ? 'discovering' : 'disabled', ...(blocked ? { diagnostic: 'Windows MCP 只能在 Windows 上使用。' } : {}) });
      if (definition.enabled && !blocked) void this.start(definition).catch(() => undefined);
    }
    this.ctx.on('agent/created', ({ agent }) => { this.applyRestriction(agent); return undefined; });
    for (const agent of this.ctx.agents.list()) this.applyRestriction(agent);
    this.ctx.effect(() => () => this.dispose(), 'workdshConnectors.runtimeClose');
  }

  async list(signal?: AbortSignal): Promise<readonly ConnectorSummary[]> {
    signal?.throwIfAborted(); const rows: ConnectorSummary[] = [];
    for (const [, definition] of this.table().entries()) rows.push(await this.summary(definition, signal));
    return rows.sort((a, b) => a.title.localeCompare(b.title, 'zh-CN'));
  }

  async config(id: string): Promise<ConnectorConfigView> {
    const row = this.definition(id);
    const credential = row.authorizationCredentialRef
      ? await this.ctx.credentials.describe(refFor(row.authorizationCredentialRef))
      : { configured: false, writable: true };
    return { id, title: row.title, description: row.description, serverName: row.serverName, transport: row.transport,
      ...(row.command ? { command: row.command } : {}), ...(row.args ? { args: row.args } : {}), ...(row.url ? { url: row.url } : {}),
      authorizationConfigured: credential.configured, authorizationWritable: credential.writable, editable: true };
  }

  async create(input: ConnectorInput): Promise<ConnectorSummary> {
    return this.enqueue(async () => {
      const normalized = this.normalize(input); this.assertUniqueServer(normalized.serverName);
      const base = idPart(normalized.serverName) || 'mcp'; let id = base;
      while (this.table().get(id)) id = `${base}-${randomUUID().slice(0, 8)}`;
      const now = new Date().toISOString();
      const authorizationCredentialRef = input.authorizationToken?.trim() ? this.credentialName(normalized.serverName) : undefined;
      if (authorizationCredentialRef) await this.ctx.credentials.set(refFor(authorizationCredentialRef), input.authorizationToken!.trim());
      const definition: ConnectorDefinition = { id, ...normalized, ...(authorizationCredentialRef ? { authorizationCredentialRef } : {}), enabled: true, createdAt: now, updatedAt: now };
      await this.table().put(id, definition); this.runtimes.set(id, { state: 'discovering' });
      await this.start(definition).catch(() => undefined);
      this.reapplyRestrictions();
      return this.summary(definition);
    });
  }

  async update(id: string, input: ConnectorInput): Promise<ConnectorSummary> {
    return this.enqueue(async () => {
      const current = this.definition(id); const normalized = this.normalize(input); this.assertUniqueServer(normalized.serverName, id);
      await this.stop(id, current.enabled);
      const authorizationCredentialRef = current.authorizationCredentialRef ?? (input.authorizationToken?.trim() ? this.credentialName(normalized.serverName) : undefined);
      if (authorizationCredentialRef && input.authorizationToken?.trim()) await this.ctx.credentials.set(refFor(authorizationCredentialRef), input.authorizationToken.trim());
      const next: ConnectorDefinition = { ...current, ...normalized, command: normalized.command, args: normalized.args, url: normalized.url,
        authorizationCredentialRef, updatedAt: new Date().toISOString() };
      await this.table().put(id, next); this.runtimes.set(id, { state: next.enabled ? 'discovering' : 'disabled' });
      if (next.enabled) await this.start(next).catch(() => undefined);
      this.reapplyRestrictions();
      return this.summary(next);
    });
  }

  async remove(id: string): Promise<void> {
    await this.enqueue(async () => {
      this.definition(id); await this.stop(id, false); await this.table().delete(id); this.runtimes.delete(id);
      await this.removeFromSelections(id); this.reapplyRestrictions();
    });
  }

  async setEnabled(id: string, enabled: boolean): Promise<ConnectorSummary> {
    return this.enqueue(async () => {
      const current = this.definition(id); if (enabled === current.enabled) return this.summary(current);
      if (enabled && this.windowsOnlyBlocked(current)) throw new Error('connector/windows-only');
      if (!enabled) { await this.stop(id, false); await this.removeFromSelections(id); }
      const next = { ...current, enabled, updatedAt: new Date().toISOString() };
      await this.table().put(id, next); this.runtimes.set(id, { state: enabled ? 'discovering' : 'disabled' });
      if (enabled) await this.start(next).catch(() => undefined);
      this.reapplyRestrictions();
      return this.summary(next);
    });
  }

  async selection(sessionId: string): Promise<readonly string[]> {
    await this.authorizeSession(sessionId);
    return [...(this.selectionTable().get(sessionId)?.connectorIds ?? [])];
  }

  async setSelection(sessionId: string, connectorIds: readonly string[]): Promise<readonly string[]> {
    await this.authorizeSession(sessionId);
    const unique = [...new Set(connectorIds)];
    for (const id of unique) {
      const definition = this.definition(id);
      if (!definition.enabled || this.runtime(id).state !== 'ready') throw new Error('connector/not-ready');
    }
    await this.authorizeSession(sessionId);
    await this.selectionTable().put(sessionId, { sessionId, connectorIds: unique, updatedAt: new Date().toISOString() });
    const agent = this.ctx.agents.get(sessionId as Agent['id']);
    if (agent) this.applyRestriction(agent);
    return unique;
  }

  async dispose(): Promise<void> { for (const [id] of this.runtimes) await this.stop(id, false); }

  private async start(definition: ConnectorDefinition): Promise<void> {
    const runtime = this.runtime(definition.id); if (runtime.child) return;
    runtime.state = 'discovering'; runtime.diagnostic = undefined;
    if (definition.id === 'libtv' && !definition.authorizationCredentialRef) {
      runtime.state = 'offline';
      runtime.diagnostic = '请先编辑并填写 LibTV 访问令牌，然后刷新状态。';
      throw new Error('connector/authorization-missing');
    }
    const authorization = definition.authorizationCredentialRef
      ? await this.ctx.credentials.resolve(refFor(definition.authorizationCredentialRef))
      : undefined;
    if (definition.authorizationCredentialRef && !authorization) {
      runtime.state = 'offline';
      runtime.diagnostic = '连接授权已失效，请重新授权。';
      throw new Error('connector/authorization-missing');
    }
    const headers: Record<string, string> = {};
    if (authorization) {
      const value = authorization.value.trim();
      headers.Authorization = /^(Bearer|Basic)\s/i.test(value) ? value : `Bearer ${value}`;
    }
    const transportConfig = definition.transport === 'stdio'
      ? { serverName: definition.serverName, transport: 'stdio' as const, ...connectorProcess(definition), env: {} }
      : { serverName: definition.serverName, transport: 'streamable-http' as const, url: definition.url!, headers };
    const fiber = this.ctx.plugin(McpClient, { ...transportConfig, failOnStartupError: true, toolCallTimeoutMs: 10_000, maxInstructionBytes: 8_192,
      reconnect: { enabled: true, initialDelayMs: 250, maxDelayMs: 5_000, maxAttempts: 4 } }) as ChildFiber & PromiseLike<unknown>;
    try { await fiber; runtime.child = fiber; runtime.state = 'ready'; }
    catch (cause) { await fiber.dispose().catch(() => undefined); runtime.state = 'offline'; runtime.diagnostic = cause instanceof Error ? cause.message : 'MCP 服务启动失败。'; throw cause; }
  }

  private async stop(id: string, remainsEnabled: boolean): Promise<void> {
    const runtime = this.runtime(id); const child = runtime.child; runtime.child = undefined;
    if (child) await child.dispose(); runtime.state = remainsEnabled ? 'offline' : 'disabled';
  }

  private async summary(definition: ConnectorDefinition, signal?: AbortSignal): Promise<ConnectorSummary> {
    const health = await this.health(definition, signal);
    return { id: definition.id, title: definition.title, description: definition.description, serverName: definition.serverName,
      transport: definition.transport, scope: 'shared', enabled: definition.enabled, state: health.state, toolNames: health.toolNames,
      resourceCount: health.resourceCount, resourceTemplateCount: health.resourceTemplateCount, lastCheckedAt: new Date().toISOString(),
      ...(health.diagnostic ? { diagnostic: health.diagnostic } : {}) };
  }

  private async health(definition: ConnectorDefinition, signal?: AbortSignal): Promise<{ state: ConnectorState; toolNames: string[]; resourceCount: number; resourceTemplateCount: number; diagnostic?: string }> {
    const runtime = this.runtime(definition.id);
    if (this.windowsOnlyBlocked(definition)) return { state: 'disabled', toolNames: [], resourceCount: 0, resourceTemplateCount: 0, diagnostic: 'Windows MCP 只能在 Windows 上使用。' };
    if (!definition.enabled) return { state: 'disabled', toolNames: [], resourceCount: 0, resourceTemplateCount: 0 };
    const prefix = `mcp__${definition.serverName}__`; const toolNames = this.ctx.tools.schemas().map(tool => tool.name).filter(name => name.startsWith(prefix));
    if (!runtime.child) return { state: runtime.state, toolNames, resourceCount: 0, resourceTemplateCount: 0, ...(runtime.diagnostic ? { diagnostic: runtime.diagnostic } : {}) };
    if (!toolNames.length) return { state: 'discovering', toolNames, resourceCount: 0, resourceTemplateCount: 0 };
    try {
      const agent = this.ctx.agents.list().find(candidate =>
        this.selectionTable().get(String(candidate.id))?.connectorIds.includes(definition.id));
      if (!agent) {
        runtime.diagnostic = '工具已连接，资源检查未完成。';
        return { state: 'ready', toolNames, resourceCount: 0, resourceTemplateCount: 0, diagnostic: runtime.diagnostic };
      }
      const call = async (name: string, args: JsonRecord) => {
        const output = await this.ctx.tools.execute({ name, arguments: args, callId: randomUUID() as never, agent, signal: signal ?? new AbortController().signal });
        if (output.isError) throw output.error; return record(output.value) ?? {};
      };
      // Resources are optional MCP capabilities. A server with working tools must not
      // be reported offline only because it does not expose resource endpoints.
      const resourceDiagnostics: string[] = [];
      const unavailable = (kind: string) => { resourceDiagnostics.push(kind); return {}; };
      const resources: JsonRecord = this.ctx.tools.get('list_mcp_resources')
        ? await call('list_mcp_resources', { server: definition.serverName }).catch(() => unavailable('resources')) : unavailable('resources');
      const templates: JsonRecord = this.ctx.tools.get('list_mcp_resource_templates')
        ? await call('list_mcp_resource_templates', { server: definition.serverName }).catch(() => unavailable('templates')) : unavailable('templates');
      runtime.state = 'ready'; runtime.diagnostic = resourceDiagnostics.length ? '工具已连接，资源检查未完成。' : undefined;
      return { state: 'ready', toolNames, ...(runtime.diagnostic ? { diagnostic: runtime.diagnostic } : {}), resourceCount: Array.isArray(resources.resources) ? resources.resources.length : 0,
        resourceTemplateCount: Array.isArray(templates.resourceTemplates) ? templates.resourceTemplates.length : 0 };
    } catch (cause) {
      runtime.state = 'offline'; runtime.diagnostic = cause instanceof Error ? cause.message : 'MCP 健康检查失败。';
      return { state: 'offline', toolNames, resourceCount: 0, resourceTemplateCount: 0, diagnostic: runtime.diagnostic };
    }
  }

  private normalize(input: ConnectorInput): Omit<ConnectorDefinition, 'id' | 'enabled' | 'createdAt' | 'updatedAt'> {
    const value = connectorDefinitionSchema.omit({ id: true, enabled: true, createdAt: true, updatedAt: true }).parse({
      title: input.title.trim(), description: input.description?.trim() ?? '', serverName: input.serverName.trim(), transport: input.transport,
      ...(input.transport === 'stdio' ? { command: input.command?.trim(), args: [...(input.args ?? [])] } : { url: input.url?.trim() }),
    });
    if (value.transport === 'stdio' && !value.command) throw new Error('connector/command-required');
    if (value.transport === 'streamable-http' && !value.url) throw new Error('connector/url-required');
    return value;
  }
  private assertUniqueServer(serverName: string, except?: string): void {
    if ([...this.table().entries()].some(([id, row]) => id !== except && row.serverName === serverName)) throw new Error('connector/server-name-conflict');
  }
  private async authorizeSession(sessionId: string): Promise<void> {
    const access = this.ctx.reflect.get('workdshSessionAccess') as { inspect(id: string): Promise<unknown> } | undefined;
    if (!access) throw new Error('connector/session-access-required');
    await access.inspect(sessionId);
  }
  private windowsOnlyBlocked(definition: Pick<ConnectorDefinition, 'id'>): boolean {
    return definition.id === 'windows-mcp' && process.platform !== 'win32';
  }
  private credentialName(serverName: string): string { return `WORKDSH_CONNECTOR_${serverName.replace(/[^A-Za-z0-9]+/g, '_').toUpperCase()}_AUTHORIZATION`; }
  private definition(id: string): ConnectorDefinition { const row = this.table().get(id); if (!row) throw new Error('connector/not-found'); return row; }
  private runtime(id: string): Runtime { let row = this.runtimes.get(id); if (!row) { row = { state: 'disabled' }; this.runtimes.set(id, row); } return row; }
  private table(): KvTable<string, ConnectorDefinition> { if (!this.definitions) throw new Error('connector/unavailable'); return this.definitions; }
  private selectionTable(): KvTable<string, ConnectorSelection> { if (!this.selections) throw new Error('connector/unavailable'); return this.selections; }
  private applyRestriction(agent: Agent): void {
    this.restrictions.get(agent)?.();
    this.restrictions.delete(agent);
    const selected = new Set(this.selectionTable().get(String(agent.id))?.connectorIds ?? []);
    const denied = [...this.table().entries()]
      .filter(([id]) => !selected.has(id))
      .flatMap(([, definition]) => this.ctx.tools.schemas().map(tool => tool.name).filter(name => name.startsWith(`mcp__${definition.serverName}__`)));
    if (denied.length) this.restrictions.set(agent, agent.ctx.tools.restrict({ deny: denied }));
  }
  private reapplyRestrictions(): void { for (const agent of this.ctx.agents.list()) this.applyRestriction(agent); }
  private async removeFromSelections(connectorId: string): Promise<void> {
    for (const [sessionId, selection] of this.selectionTable().entries()) {
      if (!selection.connectorIds.includes(connectorId)) continue;
      await this.selectionTable().put(sessionId, { ...selection, connectorIds: selection.connectorIds.filter(id => id !== connectorId), updatedAt: new Date().toISOString() });
    }
  }
  private enqueue<T>(run: () => Promise<T>): Promise<T> { const next = this.serial.then(run, run); this.serial = next.then(() => undefined, () => undefined); return next; }
}
