import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import type { RequestListener } from 'node:http'
import { createServer } from 'node:https'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { parseEnterpriseConnectionFile, readBackendPreference, readEnterpriseConnectionFile, writeBackendPreference } from '../src/enterprise-connection-file.ts'
import { EnterpriseLogin } from '../src/enterprise-auth.ts'
import { createPinnedEnterpriseRequest, probeEnterpriseConnection } from '../src/enterprise-transport.ts'

const opensslAvailable = spawnSync('openssl', ['version']).status === 0
describe.skipIf(!opensslAvailable)('offline enterprise TLS', () => {
  let dir: string
  type Tls = { key: string, cert: string }
  let good: Tls
  let other: Tls
  let wrongSan: Tls
  let expired: Tls
  function generate(name: string, san: string, old = false): Tls {
    const key = join(dir, `${name}.key`)
    const cert = join(dir, `${name}.pem`)
    const csr = join(dir, `${name}.csr`)
    const config = join(dir, `${name}.cnf`)
    writeFileSync(config, `[req]\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\n[ext]\nsubjectAltName=${san}\n`)
    const req = ['req', '-config', config, '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=praxis-test', '-keyout', key]
    if (old) {
      execFileSync('openssl', [...req, '-new', '-out', csr], { stdio: 'pipe' })
      execFileSync('openssl', ['x509', '-req', '-in', csr, '-signkey', key, '-days', '0', '-extfile', config, '-extensions', 'ext', '-out', cert], { stdio: 'pipe' })
    } else {
      execFileSync('openssl', [...req, '-x509', '-days', '1', '-out', cert], { stdio: 'pipe' })
    }
    return { key: readFileSync(key, 'utf8'), cert: readFileSync(cert, 'utf8') }
  }
  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'praxis-offline-tls-'))
    good = generate('good', 'IP:127.0.0.1')
    other = generate('other', 'IP:127.0.0.1')
    wrongSan = generate('wrong', 'DNS:other.test')
    expired = generate('expired', 'IP:127.0.0.1', true)
  }, 15_000)
  afterAll(() => { if (dir) rmSync(dir, { recursive: true, force: true }) })

  function payload(origin: string, cert = good.cert) {
    return parseEnterpriseConnectionFile({ version: 1, backendUrl: origin, serverCertificatePem: cert })
  }

  async function withServer(tls: Tls, handler: RequestListener, run: (origin: string) => Promise<void>) {
    const server = createServer(tls, handler)
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject); server.listen(0, '127.0.0.1', resolve)
    })
    try {
      const address = server.address()
      if (!address || typeof address === 'string') throw new Error('TLS server did not start')
      await run(`https://127.0.0.1:${address.port}`)
    } finally {
      server.closeAllConnections()
      await new Promise<void>(resolve => server.close(() => resolve()))
    }
  }

  it('validates format and reads saved trust without breaking old address preferences', () => {
    const file = join(dir, 'backend.json')
    const origin = 'https://company.test'
    writeFileSync(file, JSON.stringify({ backend: `${origin}/` }))
    expect(readBackendPreference(file)).toEqual({ backend: origin })
    const trust = payload(`${origin}/`)
    writeBackendPreference(file, { backend: origin, trust })
    expect(readBackendPreference(file)).toEqual({ backend: origin, trust })
    const path = join(dir, 'connection.praxis')
    writeFileSync(path, JSON.stringify(trust))
    expect(readEnterpriseConnectionFile(path)).toEqual(trust)
    writeFileSync(path, 'a'.repeat(30 * 1024))
    expect(() => readEnterpriseConnectionFile(path)).toThrow('过大')
    for (const backendUrl of ['http://127.0.0.1', `${origin}/path/..`, `${origin}?`, 'https://@company.test']) {
      expect(() => parseEnterpriseConnectionFile({ ...trust, backendUrl })).toThrow()
    }
    expect(() => parseEnterpriseConnectionFile({ ...trust, version: 2 })).toThrow()
    expect(() => parseEnterpriseConnectionFile({ ...trust, serverCertificatePem: good.cert + other.cert })).toThrow()
  })

  it('probes anonymously and uses the pinned transport for login, verification, member JSON and logout', async () => {
    const actor = { id: 'member', organizationId: 'org', organizationName: 'Company', email: 'a@company.test', displayName: 'A', role: 'MEMBER', mustChangePassword: false }
    const token = 'a'.repeat(32)
    const requests: [string | undefined, string | undefined][] = []
    await withServer(good, async (req, res) => {
      requests.push([req.url, req.headers.authorization])
      res.setHeader('Content-Type', 'application/json')
      switch (req.url) {
        case '/api/auth/login': {
          let body = ''
          for await (const chunk of req) body += chunk
          if (JSON.parse(body).password !== 'fixture-password') { res.writeHead(400).end(); return }
          res.end(JSON.stringify({ token, member: actor })); return
        }
        case '/api/auth/me':
          if (!req.headers.authorization) { res.writeHead(401).end('{}'); return }
          res.end(JSON.stringify(actor)); return
        case '/api/auth/logout': res.writeHead(204).end(); return
        default: res.end('{"ok":true}')
      }
    }, async origin => {
      const trust = payload(origin)
      await probeEnterpriseConnection(trust)
      const login = await EnterpriseLogin.login(origin, actor.email, 'fixture-password', createPinnedEnterpriseRequest(trust))
      const response = await login.request('/api/collaboration/contract')
      expect(await response.json()).toEqual({ ok: true })
      expect(await login.logout()).toBe(true)
    })
    expect(requests).toEqual([
      ['/api/auth/me', undefined], ['/api/auth/login', undefined],
      ['/api/auth/me', `Bearer ${token}`], ['/api/collaboration/contract', `Bearer ${token}`], ['/api/auth/logout', `Bearer ${token}`],
    ])
  })

  it('sends no HTTP request for a substituted, expired, or wrong-address certificate', async () => {
    for (const [tls, cert] of [[other, good.cert], [wrongSan, wrongSan.cert], [expired, expired.cert]] as const) {
      let hits = 0
      await withServer(tls, (_req, res) => { hits++; res.writeHead(500).end() }, async origin => {
        await expect(EnterpriseLogin.login(origin, 'a@company.test', 'fixture-password', createPinnedEnterpriseRequest(payload(origin, cert))))
          .rejects.toThrow('无法核验企业后台身份')
      })
      expect(hits).toBe(0)
    }
  })

  it('does not send requests to other origins, even when redirected by the trusted server', async () => {
    let hits = 0
    await withServer(good, (_req, res) => { hits++; res.writeHead(500).end() }, async destination => {
      await withServer(good, (_req, res) => { res.writeHead(307, { Location: destination }).end() }, async origin => {
        const request = createPinnedEnterpriseRequest(payload(origin))
        await expect(request(`${destination}/api/auth/me`)).rejects.toThrow('地址与连接文件不一致')
        await expect(request(`${origin}/api/auth/me`, { headers: { Authorization: 'Bearer fixture-token' } })).rejects.toThrow('跳转')
      })
    })
    expect(hits).toBe(0)
  })
})
