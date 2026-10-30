#!/usr/bin/env node
/**
 * dsh-email ships a sidebar workbench entry plus standalone chrome (package
 * name in settings nav, underlined tabs, dashed empty states). Praxis keeps
 * mail only under 设置, and uses the shared label / button / tab tokens.
 * dsh-email is optional (user-installed); missing package is a no-op.
 *
 * Usage:
 *   node scripts/praxis/patch-email-native.mjs <profile-root>
 *   node scripts/praxis/patch-email-native.mjs --self-test
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-email-native */'
const SHEET = 'const styles = `'
const CSS_JOIN = '].join("\\n");'
const TITLE_ZH = '"nav.title": "邮件 (dsh-email)"'
const TITLE_ZH_NEXT = '"nav.title": "邮件"'
const TITLE_EN = '"nav.title": "Email (dsh-email)"'
const TITLE_EN_NEXT = '"nav.title": "Email"'
const SIDEBAR = "ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({ name: 'sidebar.panellist', id, order, label }, function WorkbenchIcon({ size }) { return h(Icon, { name: icon, size }); }));"

const OVERRIDE = `
${MARKER}
.dshw{--w-bg:transparent;--w-soft:var(--dsw-alias-bg-layer-2);--w-text:var(--dsw-alias-label-primary);--w-muted:var(--dsw-alias-label-tertiary);--w-border:var(--dsw-alias-border-l2);--w-accent:var(--dsw-alias-label-primary);--w-selected:var(--dsw-alias-interactive-bg-hover);--w-primary:var(--dsw-alias-button-primary-fill);--w-on-primary:var(--dsw-alias-label-primary-inverted);background:transparent;font:14px/22px "PingFang SC","Microsoft YaHei",sans-serif}
.dshw h1{font-size:25px;line-height:34px;font-weight:600;letter-spacing:0}
.dshw h2{font-size:16px;line-height:24px;font-weight:600;letter-spacing:0}
.dshw.w-page[data-main=true],.email-workbench.dshe-settings[data-main=true]{padding:24px 24px 32px}
.w-page-header{align-items:center;gap:16px;padding-bottom:16px}
.w-subtitle{margin-top:4px!important;color:var(--dsw-alias-label-secondary);font-size:14px;line-height:22px}
.dshw .w-tabs{gap:8px;border-bottom:0}
.dshw .w-tabs>button{border:0;border-radius:8px;min-height:36px;padding:6px 12px;font-size:14px;font-weight:500;color:var(--dsw-alias-label-secondary)}
.dshw .w-tabs>button[aria-selected=true]{border-bottom-color:transparent;background:var(--dsw-alias-interactive-bg-hover);color:var(--dsw-alias-label-primary)}
.w-count,.w-tabs [aria-selected=true] .w-count{background:transparent;color:var(--dsw-alias-label-tertiary);padding:0 0 0 4px}
.dshw .w-button{background:var(--dsw-alias-bg-layer-2);border:1px solid var(--dsw-alias-border-l2);border-radius:8px;min-height:36px;font-weight:500}
.dshw .w-button:not(:disabled):hover{background:var(--dsw-alias-interactive-bg-hover)}
.dshw .w-primary,.dshw .w-primary:not(:disabled):hover{background:var(--dsw-alias-button-primary-fill);border-color:var(--dsw-alias-button-primary-fill);color:var(--dsw-alias-label-primary-inverted);opacity:1;font-weight:600}
.w-empty{gap:8px;max-width:420px;min-height:160px;padding:28px 16px}
.w-empty>svg{width:20px;height:20px;color:var(--dsw-alias-label-tertiary)}
.w-empty h2{font-size:16px;font-weight:600}
.w-empty .w-muted{font-size:13px;line-height:22px;color:var(--dsw-alias-label-tertiary)}
`

const FORM_OVERRIDE = `${MARKER} .dshe-tabs{gap:8px}.dshe-tabs [aria-selected=true]{background:var(--dsw-alias-interactive-bg-hover)!important;color:var(--dsw-alias-label-primary)!important;border-radius:8px}.dshe-btn{border-radius:8px!important;min-height:36px;font-weight:500;background:var(--dsw-alias-bg-layer-2);border:1px solid var(--dsw-alias-border-l2)}.dshe-btn.primary,.dshe-btn[data-variant=primary]{background:var(--dsw-alias-button-primary-fill)!important;border-color:var(--dsw-alias-button-primary-fill)!important;color:var(--dsw-alias-label-primary-inverted)!important;font-weight:600}.dshe-acc-empty,.dshe-prst-empty{border:0!important;border-radius:0;padding:28px 16px;text-align:start;opacity:1;color:var(--dsw-alias-label-tertiary);font-size:13px;line-height:22px;max-width:420px}.dshe-panel{border:0;border-radius:0;background:transparent;box-shadow:none;padding:16px 0}`

export function patchEmailNativeSource(source) {
  let next = source
  let changed = false

  if (next.includes(TITLE_ZH)) {
    next = next.replaceAll(TITLE_ZH, TITLE_ZH_NEXT)
    changed = true
  }
  if (next.includes(TITLE_EN)) {
    next = next.replaceAll(TITLE_EN, TITLE_EN_NEXT)
    changed = true
  }

  if (!next.includes(MARKER)) {
    const start = next.indexOf(SHEET)
    if (start < 0) throw new Error('dsh-email workbench stylesheet is missing; refuse to leave its standalone page chrome')
    const end = next.indexOf('`', start + SHEET.length)
    if (end < 0) throw new Error('dsh-email workbench stylesheet is not closed')
    next = next.slice(0, end) + OVERRIDE + next.slice(end)
    changed = true

    const closeBracket = next.indexOf(CSS_JOIN)
    if (closeBracket < 0) throw new Error('dsh-email settings CSS array is missing; refuse to leave dashed empty states')
    // Prior CSS entries already end with a trailing comma.
    const insertion = `\n            "${FORM_OVERRIDE}"\n        `
    next = next.slice(0, closeBracket) + insertion + next.slice(closeBracket)
    changed = true
  }

  // Repair an early insertion that added a spare comma before the form override.
  const spare = ',\n        ,\n            "/* praxis-email-native */'
  if (next.includes(spare)) {
    next = next.replace(spare, ',\n            "/* praxis-email-native */')
    changed = true
  }

  if (next.includes(SIDEBAR)) {
    next = next.replace(SIDEBAR, '')
    changed = true
  } else if (next.includes("ctx.slots.inject('sidebar.panellist'") || next.includes('ctx.slots.inject("sidebar.panellist"')) {
    throw new Error('dsh-email sidebar entry changed; refuse to leave 邮件 in the sidebar')
  }

  if (!next.includes(MARKER) || next.includes(TITLE_ZH) || next.includes(TITLE_EN) || next.includes("ctx.slots.inject('sidebar.panellist'") || next.includes('ctx.slots.inject("sidebar.panellist"')) {
    throw new Error('dsh-email native page patch did not apply')
  }
  if (!next.includes('settings.section')) {
    throw new Error('dsh-email settings entry was removed; refuse to leave mail without 设置')
  }
  return { source: next, changed, already: !changed }
}

export function patchEmailNativeAt(profile) {
  const path = join(profile, 'node_modules', 'dsh-email', 'lib', 'client.js')
  if (!existsSync(path)) return { path, skipped: true, changed: false, already: false }
  const patched = patchEmailNativeSource(readFileSync(path, 'utf8'))
  if (patched.changed) writeFileSync(path, patched.source)
  return { path, skipped: false, ...patched }
}

const invoked = process.argv[1]?.endsWith('patch-email-native.mjs')
if (invoked && process.argv.includes('--self-test')) {
  const sample = `function register(ctx, { id, label, icon, component, inject, order = 50 }) {\n    ctx.slots.inject('main', () => null);\n    ${SIDEBAR}\n  }\n${SHEET}\n.dshw{color:red}\n\`;\nconst CSS = [\n            ".dshe-oauth-actions{gap:8px}",\n        ${CSS_JOIN}\n${TITLE_ZH}\n${TITLE_EN}\nctx.slots.inject("settings.section", () => null);\n`
  const once = patchEmailNativeSource(sample)
  if (!once.changed || !once.source.includes(MARKER) || once.source.includes(TITLE_ZH) || once.source.includes(TITLE_EN) || !once.source.includes(TITLE_ZH_NEXT) || !once.source.includes('.dshe-acc-empty') || once.source.includes("ctx.slots.inject('sidebar.panellist'") || !once.source.includes('settings.section')) {
    throw new Error('self-test did not restyle email, hide the sidebar entry, or keep 设置')
  }
  const twice = patchEmailNativeSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  let missing = false
  try { patchEmailNativeSource('no email workbench') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown email bundle')
  console.log('email native page patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  const result = patchEmailNativeAt(process.argv[2])
  console.log(result.skipped ? 'skipped' : result.already ? 'already' : 'patched', result.path)
}
