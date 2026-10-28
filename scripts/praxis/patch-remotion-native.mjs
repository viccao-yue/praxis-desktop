#!/usr/bin/env node
/**
 * dsh-remotion ships its own workbench chrome: a large title, a black primary
 * button, and underlined tabs. Praxis pages use the shared label, button and
 * tab tokens. Append the same overrides already applied to the installed app.
 *
 * Usage:
 *   node scripts/praxis/patch-remotion-native.mjs <profile-root>
 *   node scripts/praxis/patch-remotion-native.mjs --self-test
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-remotion-native */'
const SHEET = 'const MEDIA_WORKBENCH_CSS = `'
const SETTINGS = "ctx.slots.inject('settings.section', () => ctx.slots.register({ name: 'settings.section', id: 'dsh-' + engine, order: engine === 'hyperframes' ? 62 : 63, label: () => title, inject: () => ({ locale }) }, Workbench)); "
const OVERRIDE = `
${MARKER}
.dshw{--w-bg:transparent;--w-soft:var(--dsw-alias-bg-layer-2);--w-text:var(--dsw-alias-label-primary);--w-muted:var(--dsw-alias-label-tertiary);--w-border:var(--dsw-alias-border-l2);--w-accent:var(--dsw-alias-label-primary);--w-selected:var(--dsw-alias-interactive-bg-hover);--w-primary:var(--dsw-alias-button-primary-fill);--w-on-primary:var(--dsw-alias-label-primary-inverted);background:transparent;font:14px/22px "PingFang SC","Microsoft YaHei",sans-serif}
.dshw h1{font-size:25px;line-height:34px;font-weight:600;letter-spacing:0}
.dshw h2{font-size:16px;line-height:24px;font-weight:600;letter-spacing:0}
.dshw.w-page[data-main=true],.media-workbench.dmw[data-main=true]{padding:24px 24px 32px}
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
.media-job{color:var(--dsw-alias-label-secondary);font-size:13px}
`

export function patchRemotionNativeSource(source) {
  let next = source
  let changed = false
  if (!next.includes(MARKER)) {
    const start = next.indexOf(SHEET)
    if (start < 0) throw new Error('dsh-remotion workbench stylesheet is missing; refuse to leave its standalone page chrome')
    const end = next.indexOf('`', start + SHEET.length)
    if (end < 0) throw new Error('dsh-remotion workbench stylesheet is not closed')
    next = next.slice(0, end) + OVERRIDE + next.slice(end)
    changed = true
  }
  if (next.includes(SETTINGS)) {
    next = next.replace(SETTINGS, '')
    changed = true
  } else if (next.includes("ctx.slots.inject('settings.section'")) {
    throw new Error('dsh-remotion settings entry changed; refuse to leave it in 设置')
  }
  if (!next.includes(MARKER) || next.includes("ctx.slots.inject('settings.section'")) {
    throw new Error('dsh-remotion native page patch did not apply')
  }
  return { source: next, changed, already: !changed }
}

export function patchRemotionNativeAt(profile) {
  const path = join(profile, 'node_modules', 'dsh-remotion', 'lib', 'client.js')
  const patched = patchRemotionNativeSource(readFileSync(path, 'utf8'))
  if (patched.changed) writeFileSync(path, patched.source)
}

const invoked = process.argv[1]?.endsWith('patch-remotion-native.mjs')
if (invoked && process.argv.includes('--self-test')) {
  const sample = `${SHEET}\n.media-workbench.dmw{padding:0}\n\`;\n${SETTINGS}}\n        const engine = 'remotion'\n`
  const once = patchRemotionNativeSource(sample)
  if (!once.changed || !once.source.includes(MARKER) || once.source.includes("ctx.slots.inject('settings.section'") || !once.source.includes("`;\n}\n        const engine = 'remotion'\n")) {
    throw new Error('self-test did not append the native Remotion page styles or hide the settings entry')
  }
  const twice = patchRemotionNativeSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  let missing = false
  try { patchRemotionNativeSource('no workbench') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown remotion bundle')
  console.log('remotion native page patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  patchRemotionNativeAt(process.argv[2])
}
