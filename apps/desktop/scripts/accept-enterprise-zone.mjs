#!/usr/bin/env node
/** Mac packaged enterprise-zone acceptance against a local Admin contract mock. */
import { createRequire } from 'node:module'
import { spawn, execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, createWriteStream, readFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

const require = createRequire(new URL('../../web/package.json', import.meta.url))
const { chromium } = require('@playwright/test')
const root = fileURLToPath(new URL('..', import.meta.url))
const app = process.env.WORKDSH_TEST_APP ?? fileURLToPath(new URL('../dist/mac-smoke/arm64/mac-arm64/开物Praxis.app', import.meta.url))
const executable = process.env.WORKDSH_TEST_EXECUTABLE
  ?? join(app, 'Contents/MacOS', JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).build?.executableName ?? '开物Praxis')
const directory = mkdtempSync(join(tmpdir(), 'workdsh-enterprise-gui-'))
const accountsPath = join(directory, 'accounts.json')
const report = { app, directory, checks: {} }
const mock = spawn(process.execPath, [fileURLToPath(new URL('./mock-enterprise-admin.mjs', import.meta.url))], {
  env: { ...process.env, WORKDSH_MOCK_ADMIN_PORT: process.env.WORKDSH_MOCK_ADMIN_PORT ?? '19490', WORKDSH_MOCK_ADMIN_ACCOUNTS: accountsPath },
  stdio: ['ignore', 'pipe', 'pipe'],
})
let mockInfo = ''
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('mock admin did not start')), 10_000)
  mock.stdout.on('data', chunk => {
    mockInfo += chunk.toString()
    if (mockInfo.includes('"ok":true')) { clearTimeout(timer); resolve() }
  })
  mock.stderr.on('data', chunk => { mockInfo += chunk.toString() })
  mock.once('exit', code => { clearTimeout(timer); reject(new Error('mock admin exited: ' + code + ' ' + mockInfo)) })
})
const backend = JSON.parse(mockInfo.trim().split('\n').at(-1)).origin
const accounts = JSON.parse(readFileSync(accountsPath, 'utf8'))
const member = accounts.members[0]
const env = { ...process.env, WORKDSH_DESKTOP_USER_DATA: join(directory, 'user-data'), npm_config_registry: 'https://registry.npmmirror.com' }
for (const key of Object.keys(env)) if (/KEY|SECRET|TOKEN|PASSWORD|^DSH_|^NODE_OPTIONS$|^NODE_PATH$/.test(key)) delete env[key]
mkdirSync(env.WORKDSH_DESKTOP_USER_DATA, { recursive: true })
const log = createWriteStream(join(directory, 'application.log'))
const child = spawn(executable, ['--remote-debugging-port=19532', '--remote-debugging-address=127.0.0.1'], { env, stdio: ['ignore', 'pipe', 'pipe'] })
child.stdout.pipe(log); child.stderr.pipe(log)
let browser
try {
  for (let pass = 0; pass < 100; pass++) {
    try { browser = await chromium.connectOverCDP('http://127.0.0.1:19532'); break } catch { await new Promise(r => setTimeout(r, 200)) }
  }
  if (!browser) throw new Error('Candidate did not open its test browser endpoint')
  const pages = () => browser.contexts().flatMap(c => c.pages())
  async function waitPage(test, timeout = 20_000) {
    const until = Date.now() + timeout
    while (Date.now() < until) {
      for (const page of pages()) {
        try { if (!page.isClosed() && await test(page)) return page } catch {}
      }
      await new Promise(r => setTimeout(r, 100))
    }
    throw new Error('Expected application page did not appear')
  }
  const entry = await waitPage(async page => page.getByRole('heading', { name: '选择使用方式' }).count())
  report.checks.connectionEntry = true
  await entry.locator('label[data-mode="enterprise"]').click()
  report.checks.enterpriseModeSelected = await entry.locator('input[name="mode"][value="enterprise"]').isChecked()
  await entry.locator('#portal').fill(backend)
  await entry.locator('form.enterprise-continue button.submit').click({ noWaitAfter: true })
  const login = await waitPage(async page => page.getByRole('heading', { name: '登录企业 Desktop' }).count())
  report.checks.enterpriseLoginEntry = true
  report.checks.enterprisePasswordMasked = await login.locator('#password').getAttribute('type') === 'password'
  await login.screenshot({ path: join(directory, 'enterprise-login.png') })
  await login.locator('#account').fill(member.email)
  await login.locator('#password').fill(member.password)
  await login.getByRole('button', { name: '登录并在本机运行' }).click({ noWaitAfter: true })
  const enterprise = await waitPage(async page => /^http:\/\/127\.0\.0\.1:/.test(page.url()) && await page.getByText('新会话', { exact: true }).count(), 180_000)
  report.checks.enterpriseOfficialUi = true
  const text = await enterprise.locator('body').innerText()
  report.uiSample = text.slice(0, 1200)
  await enterprise.screenshot({ path: join(directory, 'enterprise.png') })
  report.checks.settingsPresent = /设置|Settings/.test(text)
  const continueButton = enterprise.getByRole('button', { name: '继续', exact: true })
  if (await continueButton.count()) await continueButton.click()
  const collaborationLabel = enterprise.getByText(/^(协作|协同空间)$/).first()
  await collaborationLabel.waitFor({ timeout: 60_000 })
  report.checks.enterpriseCollaborationEntry = true
  await collaborationLabel.click()
  const result = await enterprise.evaluate(async () => {
    const response = await fetch('/api/workdsh-collaboration', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ endpoint: 'colleagues' }),
    })
    return { status: response.status, body: await response.json() }
  })
  report.checks.memberColleagues = result.status === 200 && result.body.ok === true
  if (!report.checks.memberColleagues) throw new Error('colleagues failed: ' + JSON.stringify(result))
  report.checks.otherMemberVisible = Array.isArray(result.body.value) && result.body.value.some(row => row.id !== member.id)
  const projectOperation = await enterprise.evaluate(async () => {
    const call = async (endpoint, payload) => {
      const response = await fetch('/api/workdsh-projects', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ endpoint, payload }),
      })
      const json = await response.json()
      if (!json.ok) throw new Error('Project operation failed: ' + endpoint)
      return json.value
    }
    const created = await call('create', { name: 'Enterprise acceptance ' + Date.now() })
    const id = created.project.id
    await call('get', { projectId: id })
    await call('archive', { projectId: id })
    return Boolean(id)
  })
  report.checks.projectCreateReadArchive = projectOperation
  const resources = join(app, 'Contents/Resources/workdsh-runtime')
  report.checks.bundledDshCommandVersion = execFileSync(join(resources, 'runtime/cli/bin/dsh'), ['--version'], { env, encoding: 'utf8', timeout: 30_000 }).trim()
  report.backend = backend
  report.ok = Object.values(report.checks).every(Boolean)
} catch (error) {
  report.ok = false
  report.error = error instanceof Error ? error.message : String(error)
} finally {
  if (browser) try { await browser.close() } catch {}
  if (child.exitCode === null) child.kill('SIGTERM')
  if (mock.exitCode === null) mock.kill('SIGTERM')
  writeFileSync(join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n')
  console.log(JSON.stringify(report, null, 2))
}
if (!report.ok) process.exitCode = 1
