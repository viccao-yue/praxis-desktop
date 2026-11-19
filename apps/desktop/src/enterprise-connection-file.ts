import { randomUUID, X509Certificate } from 'node:crypto'
import { closeSync, constants, fstatSync, openSync, readSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { enterpriseConnection } from './connection-mode.ts'

export interface EnterpriseConnectionFile {
  readonly version: 1
  readonly backendUrl: string
  readonly serverCertificatePem: string
}

export interface BackendPreference {
  backend: string
  trust?: EnterpriseConnectionFile
}

/** A manual address may be used for the current login, but only another verified import can replace saved trust. */
export function shouldRememberManualBackend(backend: string, saved?: BackendPreference, managed?: string): boolean {
  return !managed && !saved?.trust && saved?.backend !== backend
}

const maxFileSize = 24 * 1024
const certificatePem = /^-----BEGIN CERTIFICATE-----\r?\n(?:[A-Za-z0-9+/=]+\r?\n)+-----END CERTIFICATE-----(?:\r?\n)?$/

function readJson(path: string): unknown {
  const fd = openSync(path, constants.O_RDONLY | (constants.O_NONBLOCK ?? 0))
  try {
    const stat = fstatSync(fd)
    if (!stat.isFile() || stat.size > maxFileSize) throw new Error('企业连接文件无效或过大')
    const data = Buffer.alloc(maxFileSize + 1)
    let size = 0
    while (size < data.length) {
      const read = readSync(fd, data, size, data.length - size, null)
      if (!read) break
      size += read
    }
    if (size > maxFileSize) throw new Error('企业连接文件过大')
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(data.subarray(0, size)))
  } finally {
    closeSync(fd)
  }
}

export function parseEnterpriseConnectionFile(value: unknown): EnterpriseConnectionFile {
  const file = value as Partial<EnterpriseConnectionFile> | null
  if (!file || typeof file !== 'object' || Object.keys(file).length !== 3 || file.version !== 1
      || typeof file.backendUrl !== 'string' || file.backendUrl.length > 512
      || !/^https:\/\/[^/?#\\@\s]+\/?$/i.test(file.backendUrl)
      || typeof file.serverCertificatePem !== 'string' || file.serverCertificatePem.length > 16 * 1024
      || !certificatePem.test(file.serverCertificatePem)) {
    throw new Error('企业连接文件格式不正确或版本不受支持')
  }
  try { new X509Certificate(file.serverCertificatePem) }
  catch { throw new Error('企业连接文件中的服务器证书无效') }
  return Object.freeze({
    version: 1,
    backendUrl: enterpriseConnection(file.backendUrl).portalOrigin,
    serverCertificatePem: file.serverCertificatePem,
  })
}

export function readEnterpriseConnectionFile(path: string): EnterpriseConnectionFile {
  try { return parseEnterpriseConnectionFile(readJson(path)) }
  catch (error) {
    if (error instanceof SyntaxError || error instanceof TypeError)
      throw new Error('企业连接文件格式不正确，请让管理员重新发送')
    throw error
  }
}

export function readBackendPreference(path: string): BackendPreference {
  const value = readJson(path) as Partial<BackendPreference> | null
  if (typeof value?.backend !== 'string') throw new Error('无效的企业地址偏好')
  const backend = enterpriseConnection(value.backend).portalOrigin
  if (value.trust === undefined) return { backend }
  const trust = parseEnterpriseConnectionFile(value.trust)
  if (backend !== trust.backendUrl) throw new Error('已保存的企业地址与证书不匹配')
  return { backend, trust }
}

export function writeBackendPreference(path: string, preference: BackendPreference): void {
  const temporary = `${path}.${randomUUID()}.tmp`
  try {
    writeFileSync(temporary, JSON.stringify(preference), { mode: 0o600, flag: 'wx' })
    renameSync(temporary, path)
  } finally {
    rmSync(temporary, { force: true })
  }
}
