#!/usr/bin/env node
/**
 * Settings nav only paints built-in section ids. IM机器人, 视觉模型, ComfyUI
 * and 邮件 therefore share the fallback gear. Give each its own glyph. Personal
 * and enterprise homes both load this one settings shell from the installation.
 *
 * Supports both pretty (0.2.1) and compact (0.2.2+) compiled bundles.
 *
 * Usage:
 *   node scripts/praxis/patch-settings-nav-icons.mjs <profile-root>
 *   node scripts/praxis/patch-settings-nav-icons.mjs --self-test
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-settings-nav-icons */'
const PACKAGE = '@deepseek-ai/dsh-client-ui-settings-general'
const EMAIL_ID_PRETTY = 'id === "dsh-email"'
const EMAIL_ID_COMPACT = 'id===`dsh-email`'

const EMAIL_BRANCH_PRETTY = `\t\t\tif (${EMAIL_ID_PRETTY}) return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconPaperPlaneOutlineMedium, {
\t\t\t\tclassName: SettingsRoot_module_css_default.navIcon,
\t\t\t\tsize: 16
\t\t\t});
`
const EMAIL_BRANCH_COMPACT = `if(${EMAIL_ID_COMPACT})return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconPaperPlaneOutlineMedium,{size:16});`

const GEAR_FALLBACK_PRETTY = `\t\t\treturn (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSettingsOutlineMedium, {`
const GEAR_FALLBACK_COMPACT = `return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSettingsOutlineMedium,{size:16})`

const BEFORE_PRETTY = `\t\t\tif (id === "archived-sessions") return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconArchiveOutlineMedium, {
\t\t\t\tclassName: SettingsRoot_module_css_default.navIcon,
\t\t\t\tsize: 16
\t\t\t});
\t\t\treturn (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSettingsOutlineMedium, {`

const AFTER_PRETTY = `\t\t\tif (id === "archived-sessions") return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconArchiveOutlineMedium, {
\t\t\t\tclassName: SettingsRoot_module_css_default.navIcon,
\t\t\t\tsize: 16
\t\t\t});
\t\t\t${MARKER}
\t\t\tif (id === "xmanrui-dsh-im") return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconNewChatOutlineMedium, {
\t\t\t\tclassName: SettingsRoot_module_css_default.navIcon,
\t\t\t\tsize: 16
\t\t\t});
\t\t\tif (id === "vision") return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconThinkOutlineMedium, {
\t\t\t\tclassName: SettingsRoot_module_css_default.navIcon,
\t\t\t\tsize: 16
\t\t\t});
\t\t\tif (id === "comfyui") return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSparkleMedium, {
\t\t\t\tclassName: SettingsRoot_module_css_default.navIcon,
\t\t\t\tsize: 16
\t\t\t});
${EMAIL_BRANCH_PRETTY}\t\t\treturn (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSettingsOutlineMedium, {`

const BEFORE_COMPACT = `if(id===\`archived-sessions\`)return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconArchiveOutlineMedium,{size:16});return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSettingsOutlineMedium,{size:16})`

const AFTER_COMPACT = `if(id===\`archived-sessions\`)return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconArchiveOutlineMedium,{size:16});${MARKER}if(id===\`xmanrui-dsh-im\`)return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconNewChatOutlineMedium,{size:16});if(id===\`vision\`)return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconThinkOutlineMedium,{size:16});if(id===\`comfyui\`)return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSparkleMedium,{size:16});${EMAIL_BRANCH_COMPACT}return(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconSettingsOutlineMedium,{size:16})`

export function patchSettingsNavIconsSource(source) {
  let next = source
  let changed = false
  const compact = next.includes('function navIcon(id){') || next.includes(BEFORE_COMPACT)
  const markerIds = compact
    ? ['id===`xmanrui-dsh-im`', 'id===`vision`', 'id===`comfyui`']
    : ['id === "xmanrui-dsh-im"', 'id === "vision"', 'id === "comfyui"']
  const emailId = compact ? EMAIL_ID_COMPACT : EMAIL_ID_PRETTY
  const emailBranch = compact ? EMAIL_BRANCH_COMPACT : EMAIL_BRANCH_PRETTY
  const before = compact ? BEFORE_COMPACT : BEFORE_PRETTY
  const after = compact ? AFTER_COMPACT : AFTER_PRETTY
  const gearFallback = compact ? GEAR_FALLBACK_COMPACT : GEAR_FALLBACK_PRETTY

  if (!next.includes(MARKER)) {
    if (!next.includes('function navIcon(id)') || !next.includes(before)) {
      throw new Error('Settings nav icon patch: navIcon fallback is missing')
    }
    next = next.replace(before, after)
    if (next === source || !next.includes(MARKER)) throw new Error('Settings nav icon patch did not apply')
    changed = true
  }
  if (!markerIds.every((id) => next.includes(id))) {
    throw new Error('Settings nav icon patch marker is present but the three glyphs are missing')
  }
  if (!next.includes(emailId)) {
    const markerAt = next.indexOf(MARKER)
    const gearAt = next.indexOf(gearFallback, markerAt)
    if (gearAt < 0) throw new Error('Settings nav icon patch: gear fallback after marker is missing')
    next = next.slice(0, gearAt) + emailBranch + next.slice(gearAt)
    changed = true
  }
  if (!next.includes(MARKER) || !next.includes(emailId) || !next.includes('IconPaperPlaneOutlineMedium')) {
    throw new Error('Settings nav icon patch did not apply the email glyph')
  }
  return { source: next, changed, already: !changed }
}

export function patchSettingsNavIconsAt(profile) {
  const path = resolveProfilePackageFile(profile, PACKAGE, 'lib/client.js')
  const patched = patchSettingsNavIconsSource(readFileSync(path, 'utf8'))
  if (patched.changed) writeFileSync(path, patched.source)
  return { path, ...patched }
}

const invoked = process.argv[1]?.endsWith('patch-settings-nav-icons.mjs')
if (invoked && process.argv.includes('--self-test')) {
  const sample = `function navIcon(id) {\n${BEFORE_PRETTY}\n\t\t\t\tclassName: SettingsRoot_module_css_default.navIcon,\n\t\t\t\tsize: 16\n\t\t\t});\n\t\t}`
  const once = patchSettingsNavIconsSource(sample)
  if (!once.changed || !once.source.includes(MARKER) || !once.source.includes('IconNewChatOutlineMedium') || !once.source.includes('IconThinkOutlineMedium') || !once.source.includes('IconSparkleMedium') || !once.source.includes('IconPaperPlaneOutlineMedium')) {
    throw new Error('self-test did not add the settings glyphs')
  }
  if (!once.source.includes('IconSettingsOutlineMedium')) throw new Error('self-test removed the fallback gear')
  const twice = patchSettingsNavIconsSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  const withoutEmail = once.source.replace(EMAIL_BRANCH_PRETTY, '')
  const repaired = patchSettingsNavIconsSource(withoutEmail)
  if (!repaired.changed || !repaired.source.includes(EMAIL_ID_PRETTY)) throw new Error('self-test did not repair a missing email glyph')
  const compactSample = `function navIcon(id){${BEFORE_COMPACT}}`
  const compactOnce = patchSettingsNavIconsSource(compactSample)
  if (!compactOnce.changed || !compactOnce.source.includes(EMAIL_ID_COMPACT) || !compactOnce.source.includes('IconSparkleMedium')) {
    throw new Error('self-test compact did not add glyphs')
  }
  let missing = false
  try { patchSettingsNavIconsSource('function navIcon(id) { return null }') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown settings shell')
  console.log('settings nav icon patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  const result = patchSettingsNavIconsAt(process.argv[2])
  console.log(result.already ? 'already' : 'patched', result.path)
}
