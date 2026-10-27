import { expect, it } from 'vitest'
import { connectionEntryHtml, connectionLoadingHtml, enterpriseLoginHtml } from '../src/connection-entry.ts'

it('renders separate entry choices without permitting configured address HTML injection', () => {
  const html = connectionEntryHtml('\"><script>attack()</script>')
  expect(html).toContain('praxis://personal')
  expect(html).toContain('praxis://enterprise')
  expect(html).toContain('员工端')
  expect(html).toContain('开物成务')
  expect(html).toContain("default-src 'none'")
  expect(html).toContain("img-src data:")
  expect(html).toContain("form-action praxis:")
  expect(html).not.toContain('<script>')
  expect(html).not.toContain('<script>attack()')
})

it('shows an accessible loading state with reduced-motion support and escaped custom title', () => {
  const html = connectionLoadingHtml('personal', '<script>unsafe()</script>')
  expect(html).toContain('aria-busy="true"')
  expect(html).toContain('role="status"')
  expect(html).toContain('prefers-reduced-motion')
  expect(html).toContain('准备运行环境')
  expect(html).toContain('正在准备运行环境与内置插件')
  expect(html).not.toContain('<script>unsafe()')
  expect(html).not.toContain('<form')
})

it('selects loading copy by explicit kind instead of title heuristics', () => {
  expect(connectionLoadingHtml('enterprise')).toContain('正在启动企业工作区')
  expect(connectionLoadingHtml('enterprise')).toContain('正在校验企业身份')
  expect(connectionLoadingHtml('plugins')).toContain('正在更新工作区插件依赖')
  expect(connectionLoadingHtml('personal')).toContain('正在启动个人工作区')
})

it('requires installing the enterprise account plugin before showing an active login action', () => {
  const html = connectionEntryHtml('https://company.example', false, false)
  expect(html).toContain('请先安装企业账号插件')
  expect(html).toContain('type="button" disabled')
  expect(html).toContain('praxis://personal')
  expect(html).not.toContain('action="praxis://enterprise"')
})

it('styles the enterprise login surface with the shared employee brand shell', () => {
  const html = enterpriseLoginHtml('https://company.test:8443/path')
  expect(html).toContain('id="enterprise-login"')
  expect(html).toContain('id="status"')
  expect(html).toContain('company.test:8443')
  expect(html).toContain('praxis://entry')
  expect(html).toContain("form-action 'none'")
  expect(html).not.toContain('<script>')
})
