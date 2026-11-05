#!/usr/bin/env node
/**
 * @lucagiftzek/dsh-mail ships English-only UI. Praxis overlays Chinese for the
 * settings form and mail-tab chrome (company POP setup path), and fixes the
 * primary-button contrast that breaks on the light Settings page.
 *
 * Usage:
 *   node scripts/praxis/patch-dsh-mail-zh.mjs <profile-root>
 *   node scripts/praxis/patch-dsh-mail-zh.mjs --self-test
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-dsh-mail-zh */'

/**
 * Host Settings overrides / theme tokens make dsh-mail `.mlx-btn.p` render as
 * white-on-light. Match the visible outline buttons used elsewhere in Settings
 * (e.g. 保存 / 打开配置文件): bordered surface + primary label ink.
 */
const BTN_P_OUTLINE =
  '.mlx-btn.p{border:1px solid var(--dsw-alias-border-l2,var(--line,rgba(128,128,128,.35)))!important;background:var(--dsw-alias-bg-layer-2,var(--l2,rgba(128,128,128,.08)))!important;color:var(--dsw-alias-label-primary,var(--ink,#111))!important;font-weight:600}'

const CLIENT_CSS = [
  // Original upstream rule
  [
    '.mlx-btn.p{border-color:transparent;background:var(--dsw-alias-button-primary-fill,var(--brand));color:var(--on-brand);font-weight:600}',
    BTN_P_OUTLINE,
  ],
  // Previous Praxis ink-fill attempt (already applied on some installs)
  [
    '.mlx-btn.p{border-color:transparent;background:var(--dsw-alias-label-primary,#1f1f1f);color:var(--dsw-alias-label-primary-foreground,#fff);font-weight:600}',
    BTN_P_OUTLINE,
  ],
  [
    '.mlx .mlx-fab{position:absolute;right:14px;bottom:14px;width:48px;height:48px;border-radius:50%;border:0;background:var(--dsw-alias-button-primary-fill,var(--brand));color:var(--on-brand);cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 3px 10px rgba(0,0,0,.25);z-index:3}',
    '.mlx .mlx-fab{position:absolute;right:14px;bottom:14px;width:48px;height:48px;border-radius:50%;border:0;background:var(--dsw-alias-label-primary,#1f1f1f)!important;color:var(--dsw-alias-label-primary-foreground,#fff)!important;cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 3px 10px rgba(0,0,0,.25);z-index:3}',
  ],
  [
    '.mlx .mlx-fab{position:absolute;right:14px;bottom:14px;width:48px;height:48px;border-radius:50%;border:0;background:var(--dsw-alias-label-primary,#1f1f1f);color:var(--dsw-alias-label-primary-foreground,#fff);cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 3px 10px rgba(0,0,0,.25);z-index:3}',
    '.mlx .mlx-fab{position:absolute;right:14px;bottom:14px;width:48px;height:48px;border-radius:50%;border:0;background:var(--dsw-alias-label-primary,#1f1f1f)!important;color:var(--dsw-alias-label-primary-foreground,#fff)!important;cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 3px 10px rgba(0,0,0,.25);z-index:3}',
  ],
]

/** Interaction / setup-path tweaks (exact minified snippets). */
const CLIENT_UX = [
  // Company mail is POP-only for many nexwise users; default the add picker to POP3.
  // Bundled client uses the (0,I.useState)("...") form.
  ['useState)("type:imap-smtp")', 'useState)("type:pop3-smtp")'],
  ['useState("type:imap-smtp")', 'useState("type:pop3-smtp")'],
  // Settings "添加账号" must match outline 保存 buttons (drop primary class).
  ['className:"mlx-btn p",onClick:k,children:"添加账号"', 'className:"mlx-btn",onClick:k,children:"添加账号"'],
  [
    'Add your first account: any IMAP or POP3 mailbox, Gmail with an app password, or a sending service.',
    '添加第一个账号：公司邮箱选「POP3 + SMTP（公司常用）」，填入服务器、账号和密码后点保存。',
  ],
  [
    'Add your first account to read mail here.',
    '先添加邮箱账号，才能在这里收信。',
  ],
  ['Agent sends', 'Agent 发送'],
  ['Automatic', '自动'],
]

/** Exact substrings only (quoted UI literals). Longer phrases first. */
const CLIENT = [
  ['Mail accounts for the Mail tab and the mail_* agent tools. Secrets are stored in your settings and never shown again; type to replace one.',
    '这里配置「邮件」页签与 mail_* 工具用的邮箱账号。密钥保存在本机设置中，保存后不再回显；重新输入即可覆盖。'],
  ['POP3 has no server folders or flags: read state is kept locally. Messages are left on the server.',
    'POP3 没有服务端文件夹和已读标记：已读状态保存在本机。邮件默认留在服务器上。'],
  ['No account can read mail yet. Add one with the gear button.', '还没有可收信的账号。点齿轮按钮添加。'],
  ['No account can send. Add one with the gear button.', '还没有可发信的账号。点齿轮按钮添加。'],
  ['Scheduled and mass sends appear here for review.', '定时发送与群发会在这里等待你确认。'],
  ['Password from a file or an environment variable, certificates', '从文件或环境变量读取密码、证书'],
  ['Accept a self-signed certificate (only for your own server or a local bridge)', '接受自签证书（仅限自建服务器或本机桥接）'],
  ['OAuth2 with your own Google client (Workspace)', '使用自有 Google 客户端的 OAuth2（Workspace）'],
  ['App password (simplest)', '应用专用密码（最简单）'],
  ['Default sender in the composer', '设为写信默认发件人'],
  ['Agents may use this account', '允许 Agent 使用此账号'],
  ['Convert legacy settings to accounts', '将旧版服务商设置转换为账号'],
  ['Legacy provider settings in use.', '正在使用旧版服务商设置。'],
  ['Agent drafts awaiting you', '等待你确认的 Agent 草稿'],
  ['Add account / Manage', '添加账号 / 管理'],
  ['Default account for tools', '工具默认账号'],
  ['Keep cached text (days)', '本地缓存保留天数'],
  ['Max recipients per message', '单封最多收件人'],
  ['Messages per minute', '每分钟最多发送'],
  ['Messages per day', '每天最多发送'],
  ['Empty: the email address', '留空则使用邮箱地址'],
  ['Empty: the provider default', '留空则使用服务商默认值'],
  ['Save the account first.', '请先保存账号。'],
  ['Search (from:, subject:, is:unread)', '搜索（from:、subject:、is:unread）'],
  ['Instant (IMAP IDLE)', '即时（IMAP IDLE）'],
  ['Draft first, confirm every send', '先草稿，每封发送都需确认'],
  ['Send at once, draft replies only', '立即发送，仅回复走草稿'],
  ['Accounts and settings', '账号与设置'],
  ['European providers', '欧洲服务商'],
  ['Other providers', '其他服务商'],
  ['Provider documentation', '服务商文档'],
  ['Password env var', '密码环境变量'],
  ['Password file', '密码文件'],
  ['Sign-in method', '登录方式'],
  ['OAuth2 sign-in', 'OAuth2 登录'],
  ['Use a device code', '使用设备码'],
  ['TLS (implicit)', 'TLS（隐式）'],
  ['None (loopback only)', '无加密（仅本机回环）'],
  ['Test connection', '测试连接'],
  ['Connection works.', '连接成功。'],
  ['Connection works', '连接成功'],
  ['Loading accounts...', '正在加载账号…'],
  ['Select conversations', '选择会话'],
  ['Selected conversations', '已选会话'],
  ['Conversation actions', '会话操作'],
  ['Quick actions', '快捷操作'],
  ['More actions', '更多操作'],
  ['Switch account', '切换账号'],
  ['Search mail', '搜索邮件'],
  ['Message body', '邮件正文'],
  ['All inboxes', '全部收件箱'],
  ['New message', '新邮件'],
  ['New folder', '新建文件夹'],
  ['New mail', '新邮件'],
  ['Mark unread', '标为未读'],
  ['Mark read', '标为已读'],
  ['Load images', '加载图片'],
  ['Hide details', '隐藏详情'],
  ['Account types', '账号类型'],
  ['Account id', '账号 ID'],
  ['Email address', '邮箱地址'],
  ['Display name', '显示名称'],
  ['Default From', '默认发件人'],
  ['App password', '应用专用密码'],
  ['Agents and cache', 'Agent 与缓存'],
  ['All mail', '全部邮件'],
  ['Testing...', '测试中…'],
  ['Saving...', '保存中…'],
  ['Opening...', '打开中…'],
  ['Loading...', '加载中…'],
  ['Add account', '添加账号'],
  ['Not connected', '未连接'],
  ['Connected', '已连接'],
  ['Reconnect', '重新连接'],
  ['Disconnect', '断开连接'],
  ['Nothing yet.', '暂无内容。'],
  ['default account', '默认账号'],
  ['servers checked', '服务器已检测'],
  ['mass send', '群发'],
  ['unverified', '未验证'],
  ['disabled', '已禁用'],
  ['Reply-To', '回复地址'],
  ['Signature', '签名'],
  ['Security', '加密'],
  ['Incoming', '收信'],
  ['Outgoing', '发信'],
  ['Enabled', '启用'],
  ['Agents', 'Agent'],
  ['Archive', '归档'],
  ['Delete', '删除'],
  ['Refresh', '刷新'],
  ['Compose', '写信'],
  ['Settings', '设置'],
  ['Forward', '转发'],
  ['Unflag', '取消星标'],
  ['Flagged', '已加星标'],
  ['Details', '详情'],
  ['Attachment', '附件'],
  ['Folders', '文件夹'],
  ['Subject', '主题'],
  ['Cancel', '取消'],
  ['Remove', '删除'],
  ['Discard', '丢弃'],
  ['Approve', '批准'],
  ['Send now', '立即发送'],
  ['Unread', '未读'],
  ['Queue', '队列'],
  ['Login', '登录名'],
  ['Label', '显示名'],
  ['Inbox', '收件箱'],
  ['Port', '端口'],
  ['Password', '密码'],
  ['Reply', '回复'],
  ['Flag', '星标'],
  ['Save', '保存'],
  ['Edit', '编辑'],
  ['Copy', '复制'],
  ['Test', '测试'],
  ['More', '更多'],
  ['Send', '发送'],
  ['From', '发件人'],
  ['List', '列表'],
  ['Read', '已读'],
  ['Work mail', '工作邮箱'],
  ['title:"Mail"', 'title:"邮件"'],
  ['label:()=>"Mail"', 'label:()=>"邮件"'],
  // Ternary button labels (not wrapped in children:"...")
  ['?"Saving...":"Save"', '?"保存中…":"保存"'],
  ['?"Testing...":"Test connection"', '?"测试中…":"测试连接"'],
  ['?"App password":"Password"', '?"应用专用密码":"密码"'],
  ['==="google"?"App password":"Password"', '==="google"?"应用专用密码":"密码"'],
  ['?"Hide details":"Details"', '?"隐藏详情":"详情"'],
  ['?"Opening...":', '?"打开中…":'],
  ['?"Reconnect":"Connect"', '?"重新连接":"连接"'],
  ['Loading accounts...', '正在加载账号…'],
  ['+" host"', '+" 主机"'],
  ['==="receive"?"Incoming":"Outgoing"', '==="receive"?"收信":"发信"'],
]

const ACCOUNTS = [
  ["label: 'IMAP + SMTP'", "label: 'IMAP + SMTP（收发）'"],
  ["label: 'POP3 + SMTP'", "label: 'POP3 + SMTP（公司常用）'"],
  ["label: 'Self-hosted (IMAP/POP + SMTP)'", "label: '自建服务器（IMAP/POP + SMTP）'"],
]

function quotedForms(en, zh) {
  // Prefer attribute-bounded forms so bare words do not rewrite code identifiers.
  return [
    [`children:"${en}"`, `children:"${zh}"`],
    [`label:"${en}"`, `label:"${zh}"`],
    [`title:"${en}"`, `title:"${zh}"`],
    [`hint:"${en}"`, `hint:"${zh}"`],
    [`placeholder:"${en}"`, `placeholder:"${zh}"`],
    [`"aria-label":"${en}"`, `"aria-label":"${zh}"`],
    [`children:${JSON.stringify(en)}`, `children:${JSON.stringify(zh)}`],
  ]
}

function buildClientPairs() {
  const pairs = []
  for (const [en, zh] of CLIENT) {
    // Exact code snippets (ternaries / attribute rewrites) must replace as-is.
    if (
      en.includes('title:"')
      || en.includes('label:()=>')
      || en.includes('?"')
      || en.includes('===')
      || en.startsWith('+"')
    ) {
      pairs.push([en, zh])
      continue
    }
    // Long prose often appears as raw string content inside children:"..."
    pairs.push(...quotedForms(en, zh))
    // Also plain occurrence inside an already-quoted children value is covered above.
    // Keep a direct replace for long unique sentences that appear unwrapped in object maps.
    if (en.length >= 40) pairs.push([en, zh])
  }
  return pairs
}

function applyMap(source, pairs) {
  let next = source
  let changed = false
  for (const [from, to] of pairs) {
    if (!next.includes(from)) continue
    next = next.split(from).join(to)
    changed = true
  }
  return { next, changed }
}

export function patchDshMailClientSource(source) {
  const hadMarker = source.includes(MARKER)
  const bare = hadMarker
    ? source.replace(`${MARKER}\n`, '').replace(MARKER, '')
    : source
  const zh = applyMap(bare, buildClientPairs())
  const css = applyMap(zh.next, CLIENT_CSS)
  const ux = applyMap(css.next, CLIENT_UX)
  const next = ux.next
  const changed = zh.changed || css.changed || ux.changed
  if (!changed && hadMarker) return { source, changed: false, already: true }
  if (!changed) {
    // Partial overlay already applied (e.g. only children: strings) — stamp and finish.
    if (bare.includes('邮件') && bare.includes('添加账号')) {
      return { source: MARKER + '\n' + bare, changed: !hadMarker, already: hadMarker }
    }
    throw new Error('dsh-mail client had no known English UI strings to translate')
  }
  if (!next.includes('邮件') || !next.includes('添加账号')) throw new Error('dsh-mail Chinese overlay did not land')
  return { source: MARKER + '\n' + next, changed: true, already: false }
}

export function patchDshMailAccountsSource(source) {
  if (source.includes(MARKER)) return { source, changed: false, already: true }
  const { next, changed } = applyMap(source, ACCOUNTS)
  if (!changed) return { source, changed: false, already: false }
  return { source: MARKER + '\n' + next, changed: true, already: false }
}

export function patchDshMailZhAt(profile) {
  const root = join(profile, 'node_modules', '@lucagiftzek', 'dsh-mail', 'lib')
  const client = join(root, 'client.js')
  const accounts = join(root, 'accounts.js')
  const out = { skipped: !existsSync(client), client: null, accounts: null }
  if (out.skipped) return out
  const c = patchDshMailClientSource(readFileSync(client, 'utf8'))
  if (c.changed) writeFileSync(client, c.source)
  out.client = c
  if (existsSync(accounts)) {
    const a = patchDshMailAccountsSource(readFileSync(accounts, 'utf8'))
    if (a.changed) writeFileSync(accounts, a.source)
    out.accounts = a
  }
  return out
}

const invoked = process.argv[1]?.endsWith('patch-dsh-mail-zh.mjs')
if (invoked && process.argv.includes('--self-test')) {
  const sample = [
    'label:()=>"Mail"',
    'title:"Mail"',
    'children:"Add account"',
    'label:"Email address"',
    'children:"Test connection"',
    'useState("type:imap-smtp")',
    '.mlx-btn.p{border-color:transparent;background:var(--dsw-alias-button-primary-fill,var(--brand));color:var(--on-brand);font-weight:600}',
  ].join('\n')
  const once = patchDshMailClientSource(sample)
  if (!once.changed || !once.source.includes('邮件') || !once.source.includes('添加账号') || !once.source.includes(MARKER)) {
    throw new Error('self-test did not translate dsh-mail UI')
  }
  if (!once.source.includes('type:pop3-smtp') || !once.source.includes('label-primary,var(--ink,#111))!important')) {
    throw new Error('self-test did not apply primary-button / POP3 UX fixes')
  }
  const twice = patchDshMailClientSource(once.source)
  if (!twice.already) throw new Error('self-test was not idempotent')
  const acc = patchDshMailAccountsSource("  'pop3-smtp': { label: 'POP3 + SMTP', receive: 'pop3', send: 'smtp' },\n")
  if (!acc.changed || !acc.source.includes('公司常用')) throw new Error('self-test did not translate account types')
  console.log('dsh-mail zh patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  const result = patchDshMailZhAt(process.argv[2])
  if (result.skipped) console.log('skipped (package missing)')
  else console.log(result.client?.already && (!result.accounts || result.accounts.already) ? 'already' : 'patched', join(process.argv[2], 'node_modules/@lucagiftzek/dsh-mail/lib/client.js'))
}
