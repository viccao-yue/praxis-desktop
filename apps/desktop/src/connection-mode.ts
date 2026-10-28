import { createHash } from 'node:crypto'

export type DesktopConnection =
  | { mode: 'personal' }
  | { mode: 'enterprise', portalOrigin: string, organizationId?: string, principalId?: string }

/** Backend configuration is independent of the local official Host address. */
export function enterpriseConnection(value: string): DesktopConnection & { mode: 'enterprise' } {
  const url = new URL(value)
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) {
    throw new Error('企业地址必须使用 HTTPS；仅本机测试允许 HTTP')
  }
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('请输入企业后台地址，不包含账号、令牌或页面路径')
  }
  return { mode: 'enterprise', portalOrigin: url.origin }
}

/** Ephemeral enterprise browser state is separate from the existing personal session. */
export function connectionPartition(connection: DesktopConnection): string | undefined {
  if (connection.mode === 'personal') return undefined
  const origin = enterpriseConnection(connection.portalOrigin).portalOrigin
  return `workdsh-enterprise-${enterpriseNamespace(origin, connection.organizationId ?? '', connection.principalId ?? '')}`
}

export function enterpriseNamespace(origin: string, organizationId: string, principalId: string): string {
  return createHash('sha256').update(JSON.stringify([enterpriseConnection(origin).portalOrigin, organizationId, principalId])).digest('hex')
}

/** Settings 「连接企业」 and the carrier entry both return to the mode chooser. */
export function isReturnToEntryUrl(target: string): boolean {
  try {
    const url = new URL(target)
    return (url.protocol === 'praxis:' || url.protocol === 'workdsh:') && url.hostname === 'entry' && (url.pathname === '' || url.pathname === '/')
  } catch {
    return false
  }
}
