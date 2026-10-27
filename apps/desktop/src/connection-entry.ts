/** Carrier connection UI only; login and all product features remain in the Profile/server. */
import { brandLogoDataUri } from './connection-brand-logo.ts'
import { shellCss } from './connection-ui/shell-css.ts'

export type ConnectionLoadingKind = 'personal' | 'enterprise' | 'plugins'

const escapeHtml = (value: string): string =>
  value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' } as const)[char as '&' | '<' | '>' | '"' | "'"]!)

const loadingCopy: Record<ConnectionLoadingKind, { title: string, description: string }> = {
  personal: {
    title: '正在启动个人工作区',
    description: '正在准备运行环境与内置插件，请稍候。运行环境和内置插件已随安装包提供。',
  },
  enterprise: {
    title: '正在启动企业工作区',
    description: '正在校验企业身份并同步工作区配置，请稍候。运行环境和内置插件已随安装包提供。',
  },
  plugins: {
    title: '正在更新工作区插件依赖',
    description: '正在准备工作区并安装插件依赖，请稍候。运行环境和内置插件已随安装包提供。',
  },
}

function backendHost(backend: string): string {
  try {
    const url = new URL(backend)
    return url.host || backend
  } catch {
    return backend
  }
}

function documentShell(title: string, csp: string, stage: string): string {
  return `<!doctype html><html lang="zh-CN"><head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>${shellCss}</style>
</head><body>
<main class="shell">
  <section class="brand-panel">
    <div class="ring ring-1"></div>
    <div class="ring ring-2"></div>
    <div class="lockup"><img class="brand-logo" src="${brandLogoDataUri()}" alt="开物 Praxis"></div>
    <div class="copy">
      <div class="eyebrow"><i></i>员工端</div>
      <h1>开物成务</h1>
      <p class="slogan">洞察事物之理，成就企业之务。</p>
      <ul class="feat">
        <li>个人空间与企业空间相互隔离</li>
        <li>一处登录，随处调用企业模型</li>
        <li>数据在本机运行，不外传</li>
      </ul>
    </div>
    <div class="brand-foot">
      <span>KAIWU PRAXIS</span>
      <span><span class="dot"></span>本机就绪</span>
    </div>
  </section>
  <section class="stage-side"><div class="stage">${stage}</div></section>
</main>
</body></html>`
}

const entryCsp = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action workdsh:; base-uri 'none'"
const loginCsp = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'"
const loadingCsp = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'"

export function connectionEntryHtml(portal: string, managed: boolean = false, enterpriseAvailable = true): string {
  const escaped = escapeHtml(portal)
  const portalField = managed
    ? `<div class="field" id="server-field"><label>企业后台</label><p class="managed-portal">${escaped}</p></div>`
    : `<div class="field" id="server-field"><label for="portal">企业后台地址</label><div class="control"><input class="mono" id="portal" name="portal" type="url" required placeholder="https://企业地址" value="${escaped}" autocomplete="url" spellcheck="false"></div></div>`
  const enterpriseAction = enterpriseAvailable
    ? `<form class="enterprise-continue" action="workdsh://enterprise" method="get">${portalField}<button class="submit" type="submit">下一步</button></form>`
    : `<div class="enterprise-continue">${portalField}<button class="submit" type="button" disabled>请先安装企业账号插件</button><p class="plugin-hint">进入个人空间，在插件管理中安装企业插件，再从工作区菜单切换到企业登录。</p></div>`
  const enterpriseOption = enterpriseAvailable
    ? `<label class="option" data-mode="enterprise"><input type="radio" name="mode" value="enterprise"><span class="txt"><strong>企业登录</strong><small>连接企业后台，使用企业空间与统一权限</small></span><span class="radio" aria-hidden="true"></span></label>`
    : `<label class="option is-disabled" data-mode="enterprise" aria-disabled="true"><input type="radio" name="mode" value="enterprise" disabled><span class="txt"><strong>企业登录</strong><small>请先安装企业账号插件后再使用</small></span><span class="radio" aria-hidden="true"></span></label>`

  const stage = `
      <div class="screen is-active" id="s-mode">
        <div class="head">
          <h2>选择使用方式</h2>
          <p>官方 DSH 在本机运行。个人与企业使用独立空间。</p>
        </div>
        <div class="options" role="radiogroup" aria-label="使用方式">
          <label class="option" data-mode="personal">
            <input type="radio" name="mode" value="personal" checked>
            <span class="txt">
              <strong>个人使用</strong>
              <small>直接在本机启动个人工作区，无需账号</small>
            </span>
            <span class="radio" aria-hidden="true"></span>
          </label>
          ${enterpriseOption}
        </div>
        <a class="submit personal-continue" href="workdsh://personal">继 续</a>
        ${enterpriseAction}
      </div>`

  return documentShell('开物Praxis', entryCsp, stage)
}

export function enterpriseLoginHtml(backend: string): string {
  const escaped = escapeHtml(backend)
  const host = escapeHtml(backendHost(backend))
  const stage = `
      <div class="screen is-active" id="s-login">
        <div class="head">
          <h2>登录企业 Desktop</h2>
          <p>使用企业账号登录，账号权限与企业后台保持一致。</p>
        </div>
        <div class="server">
          <span class="lamp" aria-hidden="true"></span>
          <code title="${escaped}">${host}</code>
          <a class="switch" href="workdsh://entry">切换</a>
        </div>
        <form id="enterprise-login" novalidate>
          <div class="field" id="f-account">
            <label for="account">账号</label>
            <div class="control">
              <input id="account" name="account" type="text" placeholder="企业邮箱或工号" autocomplete="username" spellcheck="false" required maxlength="254">
            </div>
          </div>
          <div class="field" id="f-password">
            <label for="password">密码</label>
            <div class="control has-action">
              <input id="password" name="password" type="password" placeholder="请输入登录密码" autocomplete="current-password" required maxlength="512">
              <button class="reveal" type="button" id="reveal" aria-label="显示密码" aria-pressed="false">
                <svg width="18" height="18" viewBox="0 0 20 20" fill="none" aria-hidden="true">
                  <path d="M2 10s2.9-5 8-5 8 5 8 5-2.9 5-8 5-8-5-8-5Z" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>
                  <circle cx="10" cy="10" r="2.3" stroke="currentColor" stroke-width="1.4"/>
                  <path id="slash" d="M4 16 16 4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" hidden/>
                </svg>
              </button>
            </div>
          </div>
          <div class="status" id="status-box" role="status">
            <svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.4"/>
              <path d="M8 4.6v4.2M8 11.4v.2" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
            </svg>
            <span id="status"></span>
          </div>
          <button class="submit" type="submit">登录并在本机运行</button>
        </form>
        <a class="back" href="workdsh://entry">返回使用方式</a>
      </div>`
  return documentShell('开物Praxis', loginCsp, stage)
}

/** Trusted carrier loading surface; no remote content or credentials are embedded. */
export function connectionLoadingHtml(kind: ConnectionLoadingKind, title?: string): string {
  const copy = loadingCopy[kind]
  const escapedTitle = escapeHtml(title ?? copy.title)
  const stage = `
      <div class="screen is-active" id="s-launch" aria-busy="true">
        <div class="head">
          <h2 id="launch-title" role="status">${escapedTitle}</h2>
          <p id="launch-desc">${copy.description}</p>
        </div>
        <div class="track" aria-hidden="true"></div>
        <ul class="steps" id="steps">
          <li class="is-active"><span class="d"></span>准备运行环境</li>
          <li><span class="d"></span>装载内置插件</li>
          <li><span class="d"></span>启动工作区</li>
        </ul>
      </div>`
  return documentShell('开物Praxis', loadingCsp, stage)
}
