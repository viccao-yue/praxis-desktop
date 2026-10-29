#!/usr/bin/env node
/**
 * dsh-ui-appearance paints settings dialogs with a light surface.
 * That rule is rooted at :is(#root, body), so its specificity beats the
 * dark-mode rule. Official dark theme sets body[data-ds-dark-theme]. The
 * settings panel is portaled onto document.body, beside #root, so a dark
 * rule that requires a #root ancestor never matches it: the surface stays
 * white while the text follows the light-on-dark ink.
 * Give the dark rule the same #root specificity on the theme element itself.
 *
 * Usage:
 *   node scripts/praxis/patch-appearance-dark-dialog.mjs <profile-root>
 *   node scripts/praxis/patch-appearance-dark-dialog.mjs --self-test
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-dark-dialog */'
const LIGHT = ':is(#root, body) :is(\n  [role="dialog"],'
const THEME = ':is(html[data-ds-dark-theme], html[data-theme="dark"], body[data-ds-dark-theme], body[data-theme="dark"])'
const DARK = `${THEME} :is(\n  [role="dialog"],`
const BROKEN = `${THEME} :is(#root, body) :is(\n  [role="dialog"], ${MARKER}`
const FIXED = `${THEME}:is(#root, body, html) :is(\n  [role="dialog"], ${MARKER}`

export function patchAppearanceDarkDialogSource(source) {
  if (source.includes(FIXED)) return { source, changed: false, already: true }
  if (source.includes(BROKEN)) {
    const next = source.replace(BROKEN, FIXED)
    if (!next.includes(FIXED) || next.includes(BROKEN)) throw new Error('dsh-ui-appearance dark dialog patch did not repair the portaled settings panel')
    return { source: next, changed: true, already: false }
  }
  if (source.includes(MARKER)) throw new Error('dsh-ui-appearance dark dialog marker is present in an unknown form')
  if (!source.includes(LIGHT) || !source.includes(DARK)) {
    throw new Error('dsh-ui-appearance settings dialog theme markers are missing; refuse to leave dark mode on the light dialog surface')
  }
  const next = source.replace(DARK, FIXED)
  if (next === source || !next.includes(FIXED) || !next.includes(LIGHT)) {
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
  if (!once.changed || !once.source.includes(FIXED) || once.source.includes(`${THEME} :is(#root, body)`)) {
    throw new Error('self-test did not raise the dark dialog rule for a body-portaled panel')
  }
  if (!once.source.includes(LIGHT)) throw new Error('self-test removed the light dialog rule')
  const twice = patchAppearanceDarkDialogSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  const repaired = patchAppearanceDarkDialogSource(sample.replace(DARK, BROKEN))
  if (!repaired.changed || !repaired.source.includes(FIXED) || repaired.source.includes(BROKEN)) {
    throw new Error('self-test did not repair the previous #root descendant selector')
  }
  let missing = false
  try { patchAppearanceDarkDialogSource('no dialog theme') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown appearance bundle')
  console.log('appearance dark dialog patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  patchAppearanceDarkDialogAt(process.argv[2])
}
