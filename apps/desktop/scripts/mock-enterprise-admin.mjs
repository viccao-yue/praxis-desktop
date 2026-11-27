#!/usr/bin/env node
/** Local kaiwu Admin contract mock for Desktop enterprise-zone acceptance. */
import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'
import { writeFileSync } from 'node:fs'

const port = Number(process.env.WORKDSH_MOCK_ADMIN_PORT ?? 19490)
const members = [
  {
    id: '11111111-1111-4111-8111-111111111111',
    organizationId: 'org-acceptance',
    organizationName: '验收组织',
    displayName: '甲',
    email: 'a@example.test',
    role: 'MEMBER',
    mustChangePassword: false,
    password: 'fixture-password',
  },
  {
    id: '22222222-2222-4222-8222-222222222222',
    organizationId: 'org-acceptance',
    organizationName: '验收组织',
    displayName: '乙',
    email: 'b@example.test',
    role: 'MEMBER',
    mustChangePassword: false,
    password: 'fixture-password',
  },
]
const tokens = new Map()

function json(response, status, value) {
  response.writeHead(status, { 'content-type': 'application/json' })
  response.end(JSON.stringify(value))
}

async function readBody(request) {
  const chunks = []
  for await (const chunk of request) chunks.push(chunk)
  if (!chunks.length) return undefined
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

function actorFrom(request) {
  const header = request.headers.authorization
  if (!header?.startsWith('Bearer ')) return undefined
  return tokens.get(header.slice(7))
}

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? '/', `http://127.0.0.1:${port}`)
    const path = url.pathname
    if (request.method === 'GET' && path === '/api/auth/me' && !request.headers.authorization) {
      return json(response, 401, {})
    }
    if (request.method === 'POST' && path === '/api/auth/login') {
      const body = await readBody(request)
      const member = members.find(row => row.email === String(body?.email ?? '').trim())
      if (!member || body?.password !== member.password) return json(response, 401, { detail: '账号或密码不正确' })
      const token = randomBytes(24).toString('hex')
      tokens.set(token, member)
      const { password: _password, ...publicMember } = member
      return json(response, 200, { token, member: publicMember })
    }
    const actor = actorFrom(request)
    if (!actor) return json(response, 401, {})
    if (request.method === 'GET' && path === '/api/auth/me') {
      const { password: _password, ...publicMember } = actor
      return json(response, 200, publicMember)
    }
    if (request.method === 'POST' && path === '/api/auth/logout') {
      for (const [token, member] of tokens) if (member.id === actor.id) tokens.delete(token)
      response.writeHead(204).end()
      return
    }
    if (request.method === 'GET' && path === '/api/collaboration/contract') {
      return json(response, 200, { contractVersion: 1 })
    }
    if (request.method === 'GET' && path === '/api/collaboration/colleagues') {
      return json(response, 200, members
        .filter(row => row.id !== actor.id)
        .map(({ id, displayName, email }) => ({ id, displayName, email })))
    }
    if (request.method === 'GET' && (path === '/api/collaboration/inbox' || path === '/api/collaboration/sent')) {
      return json(response, 200, [])
    }
    if (request.method === 'GET' && path === '/api/collaboration/notifications') {
      return json(response, 200, [])
    }
    return json(response, 404, { detail: `unhandled ${request.method} ${path}` })
  } catch (error) {
    json(response, 500, { detail: error instanceof Error ? error.message : String(error) })
  }
})

server.listen(port, '127.0.0.1', () => {
  const accounts = {
    members: members.map(({ id, email, password, displayName, organizationId }) => ({
      id, email, password, displayName, organizationId,
    })),
  }
  const accountsPath = process.env.WORKDSH_MOCK_ADMIN_ACCOUNTS
  if (accountsPath) writeFileSync(accountsPath, JSON.stringify(accounts, null, 2) + '\n')
  process.stdout.write(JSON.stringify({
    ok: true,
    origin: `http://127.0.0.1:${port}`,
    accountsPath: accountsPath ?? null,
  }) + '\n')
})
