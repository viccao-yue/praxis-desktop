#!/usr/bin/env node
/**
 * dsh-ui-appearance paints settings dialogs with a light surface.
 * That rule is rooted at #root, so its specificity beats the dark-mode
 * rule. Official dark theme sets body[data-ds-dark-theme], and the settings
 * dialog lives under #root, so the dialog stays white while its text follows
 * the light-on-dark ink. Raise the dark rule to the same #root root.
 *
 * Usage:
 *   node scripts/praxis/patch-appearance-dark-dialog.mjs <profile-root>
 *   node scripts/praxis/patch-appearance-dark-dialog.mjs --self-test
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-dark-dialog */'
const LIGHT = ':is(#root, body) :is(\n  [role="dialog"],'
const DARK = ':is(html[data-ds-dark-theme], html[data-theme="dark"], body[data-ds-dark-theme], body[data-theme="dark"]) :is(\n  [role="dialog"],'
const DARK_FIXED = `:is(html[data-ds-dark-theme], html[data-theme="dark"], body[data-ds-dark-theme], body[data-theme="dark"]) :is(#root, body) :is(\n  [role="dialog"], ${MARKER}`

export function patchAppearanceDarkDialogSource(source) {
  if (source.includes(MARKER)) return { source, changed: false, already: true }
  if (!source.includes(LIGHT) || !source.includes(DARK)) {
    throw new Error('dsh-ui-appearance settings dialog theme markers are missing; refuse to leave dark mode on the light dialog surface')
  }
  const next = source.replace(DARK, DARK_FIXED)
  if (next === source || !next.includes(MARKER) || !next.includes(':is(#root, body) :is(\n  [role="dialog"], ' + MARKER)) {
    throw new Error('dsh-ui-appearance dark dialog patch did not apply')
  }
  return { source: next, changed: true, already: false }
}

export function patchAppearanceDarkDialogAt(profile) {
  const path = join(profile, 'node_modules', 'dsh-ui-appearance', 'lib', 'client.js')
  const patched = patchAppearanceDarkDialogSource(readFileSync(path, 'utf8'))
  if (patched.changed) writeFileSync(path, patched.source)
}

const invoked = process.argv[1]?.endsWith('patch-appearance-dark-dialog.mjs')
if (invoked && process.argv.includes('--self-test')) {
  const sample = `${LIGHT}\n}\n${DARK}\n}`
  const once = patchAppearanceDarkDialogSource(sample)
  if (!once.changed || !once.source.includes(MARKER) || !once.source.includes(':is(#root, body) :is(\n  [role="dialog"], ' + MARKER)) {
    throw new Error('self-test did not raise the dark dialog rule')
  }
  if (!once.source.includes(LIGHT)) throw new Error('self-test removed the light dialog rule')
  const twice = patchAppearanceDarkDialogSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  let missing = false
  try { patchAppearanceDarkDialogSource('no dialog theme') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown appearance bundle')
  console.log('appearance dark dialog patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  patchAppearanceDarkDialogAt(process.argv[2])
}
