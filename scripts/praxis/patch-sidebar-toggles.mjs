#!/usr/bin/env node
/**
 * dsh-better-sidebar hides the on/off knob when a side card is off.
 * Praxis keeps Git / Diff off by default, and the knob has to stay visible
 * so 设置 → 侧边卡片 can turn them back on. The card was already clickable.
 *
 * Usage:
 *   node scripts/praxis/patch-sidebar-toggles.mjs <profile-root>
 *   node scripts/praxis/patch-sidebar-toggles.mjs --self-test
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-sidebar-toggle-visible */'
const PATTERN = /props\.enabled && (\/\* @__PURE__ \*\/ )?\(0, react_jsx_runtime\.jsx\)\("span", \{\s*className: SideCardSection_module_css_default\.cardSwitch,/g

export function patchSidebarToggleSource(source) {
  if (source.includes(MARKER)) return { source, changed: false, already: true }
  PATTERN.lastIndex = 0
  if (!PATTERN.test(source)) throw new Error('better-sidebar side-card switch marker is missing; refuse to hide disabled toggles')
  PATTERN.lastIndex = 0
  const next = source.replace(PATTERN, match => match.replace('props.enabled && ', `${MARKER} `))
  if (next === source || !next.includes(MARKER)) throw new Error('better-sidebar side-card switch patch did not apply')
  return { source: next, changed: true, already: false }
}

export function patchSidebarTogglesAt(profile) {
  const root = join(profile, 'node_modules', 'dsh-better-sidebar', 'lib')
  const files = ['client.js', 'client-registry.js']
  for (const name of files) {
    const path = join(root, name)
    const current = readFileSync(path, 'utf8')
    const patched = patchSidebarToggleSource(current)
    if (patched.changed) writeFileSync(path, patched.source)
  }
}

if (process.argv[1] && process.argv[1].endsWith('patch-sidebar-toggles.mjs') && process.argv.includes('--self-test')) {
  const sample = 'props.enabled && /* @__PURE__ */ (0, react_jsx_runtime.jsx)("span", {\n\tclassName: SideCardSection_module_css_default.cardSwitch,'
  const once = patchSidebarToggleSource(sample)
  if (!once.changed || once.source.includes('props.enabled &&') || !once.source.includes(MARKER)) throw new Error('self-test did not reveal the off switch')
  const twice = patchSidebarToggleSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  let missing = false
  try { patchSidebarToggleSource('no switch here') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown sidebar bundle')
  console.log('sidebar toggle patch self-test ok')
}
