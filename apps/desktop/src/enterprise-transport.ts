import { X509Certificate } from 'node:crypto'
import { request } from 'node:https'
import { isIP } from 'node:net'
import { Readable } from 'node:stream'
import { checkServerIdentity } from 'node:tls'
import type { EnterpriseConnectionFile } from './enterprise-connection-file.ts'

export class EnterpriseTransportError extends Error {}

const identityError = () => new EnterpriseTransportError('无法核验企业后台身份：证书不匹配、无效或已过期，请联系管理员')

export function createPinnedEnterpriseRequest(connection: EnterpriseConnectionFile): typeof fetch {
  const { backendUrl, serverCertificatePem } = connection
  const pinned = new X509Certificate(serverCertificatePem)
  return async (input, init) => {
    if (typeof input !== 'string' && !(input instanceof URL))
      throw new EnterpriseTransportError('不支持此企业请求格式')
    const target = new URL(input)
    if (target.origin !== backendUrl || target.protocol !== 'https:' || target.username || target.password || target.hash)
      throw new EnterpriseTransportError('企业请求地址与连接文件不一致')
    const body = init?.body
    if (body != null && typeof body !== 'string') throw new EnterpriseTransportError('不支持此企业请求内容')
    const headers = new Headers(init?.headers)
    headers.set('Accept-Encoding', 'identity')
    if (body != null) headers.set('Content-Length', String(Buffer.byteLength(body)))
    return new Promise<Response>((resolve, reject) => {
      const req = request(target, {
        method: init?.method,
        headers: Object.fromEntries(headers),
        signal: init?.signal ?? undefined,
        // No shared sockets or cached TLS sessions: each handshake checks this exact peer.
        agent: false,
        ca: serverCertificatePem,
        rejectUnauthorized: true,
        checkServerIdentity(hostname, peer) {
          if (checkServerIdentity(hostname, peer) || !peer.raw) return identityError()
          const presented = new X509Certificate(peer.raw)
          const host = target.hostname.replace(/^\[|\]$/g, '')
          const san = isIP(host) ? presented.checkIP(host) : presented.checkHost(host, { subject: 'never' })
          return !san || presented.fingerprint256 !== pinned.fingerprint256 ? identityError() : undefined
        },
      }, response => {
        const status = response.statusCode ?? 502
        if (status >= 300 && status < 400) {
          response.destroy()
          reject(new EnterpriseTransportError('企业后台返回了跳转，请联系管理员检查连接地址'))
          return
        }
        try {
          const responseHeaders = new Headers()
          for (const [name, value] of Object.entries(response.headers)) {
            if (Array.isArray(value)) for (const item of value) responseHeaders.append(name, item)
            else if (value !== undefined) responseHeaders.append(name, value)
          }
          const noBody = status === 204 || status === 205 || init?.method?.toUpperCase() === 'HEAD'
          if (noBody) response.resume()
          resolve(new Response(noBody ? null : Readable.toWeb(response) as ReadableStream<Uint8Array>, {
            status, statusText: response.statusMessage ?? '', headers: responseHeaders,
          }))
        } catch (error) {
          response.destroy()
          reject(error)
        }
      })
      req.on('error', (error: NodeJS.ErrnoException) => {
        const tlsFailure = /CERT|ISSUER|SELF_SIGNED|^ERR_TLS_/.test(error.code ?? '')
        reject(tlsFailure ? identityError() : error)
      })
      req.end(body ?? undefined)
    })
  }
}

export async function probeEnterpriseConnection(connection: EnterpriseConnectionFile): Promise<void> {
  const response = await createPinnedEnterpriseRequest(connection)(`${connection.backendUrl}/api/auth/me`, {
    headers: { Accept: 'application/json' },
    redirect: 'error',
    signal: AbortSignal.timeout(10_000),
  }).catch(error => {
    if (error instanceof EnterpriseTransportError) throw error
    throw new Error('无法连接企业后台，请检查地址和网络')
  })
  await response.body?.cancel()
  if (response.status !== 401) throw new EnterpriseTransportError('该地址未返回预期的企业后台响应，请联系管理员')
}
