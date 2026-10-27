#!/usr/bin/env node
/**
 * Replace official sidebar glyphs that Praxis does not own:
 * 插件 pinwheel → plug, 自动化任务 plain clock → alarm clock.
 *
 * Usage:
 *   node scripts/praxis/patch-sidebar-icons.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-sidebar-icons.mjs --self-test
 */
import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-sidebar-icons-patched */'

const svg = (d) => `return (0, react_jsx_runtime.jsx)("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.7, strokeLinecap: "round", strokeLinejoin: "round", "aria-hidden": true, focusable: "false", children: (0, react_jsx_runtime.jsx)("path", { d: "${d}" }) });`

const replacements = [
  {
    packageName: '@deepseek-ai/dsh-client-ui-schedule',
    from: 'return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconClockOutlineRegular, { size });',
    to: svg('M12 7.5v5l3.5 2M5.2 4.2L3 6.5M18.8 4.2L21 6.5M5.2 19.8L3 17.5M18.8 19.8L21 17.5M21 12a9 9 0 11-18 0 9 9 0 0118 0'),
    expect: 'TaskManagerIcon',
  },
  {
    packageName: '@deepseek-ai/dsh-client-ui-plugin-manager',
    from: 'return (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconPluginPinwheelOutlineRegular, { size });',
    to: svg('M9 3v4M15 3v4M7 7h10v6a5 5 0 01-10 0V7zM12 18v3'),
    expect: 'PluginsPanelIcon',
  },
]

function resolveBundle(root, spec) {
  try {
    return resolveProfilePackageFile(root, spec.packageName, 'lib/client.js')
  } catch (cause) {
    throw new Error('Sidebar icon patch: missing ' + spec.packageName + '/lib/client.js', { cause })
  }
}

/** Replace one official sidebar icon return. */
export function patchSidebarIconSource(source, spec) {
  if (source.includes(MARKER) && source.includes(spec.to)) return { source, changed: false, already: true }
  const at = source.indexOf(`function ${spec.expect}(`)
  if (at < 0) throw new Error('Sidebar icon patch: ' + spec.expect + ' missing')
  const window = source.slice(at, at + 600)
  if (!window.includes(spec.from)) throw new Error('Sidebar icon patch: ' + spec.expect + ' glyph missing')
  const next = source.slice(0, at) + window.replace(spec.from, spec.to) + source.slice(at + window.length)
  if (!next.includes(MARKER)) return { source: MARKER + '\n' + next, changed: true, already: false }
  return { source: next, changed: true, already: false }
}

export function patchSidebarIconsAt(root) {
  const results = []
  for (const spec of replacements) {
    const file = resolveBundle(root, spec)
    const before = readFileSync(file, 'utf8')
    const result = patchSidebarIconSource(before, spec)
    if (result.changed) writeFileSync(file, result.source)
    results.push({ file, ...result })
  }
  return results
}

function selfTest() {
  const sample = `function TaskManagerIcon({ size }) {\n\t\t\treturn (0, react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconClockOutlineRegular, { size });\n\t\t}`
  const once = patchSidebarIconSource(sample, replacements[0])
  if (!once.changed || once.source.includes('IconClockOutlineRegular')) throw new Error('self-test: clock remains')
  const twice = patchSidebarIconSource(once.source, replacements[0])
  if (!twice.already) throw new Error('self-test: expected idempotent skip')
  console.log('patch-sidebar-icons self-test ok')
}

const isMain = process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const args = process.argv.slice(2)
  if (args[0] === '--self-test') selfTest()
  else if (!args[0]) {
    console.error('Usage: node scripts/praxis/patch-sidebar-icons.mjs <profile-or-package-root> | --self-test')
    process.exit(2)
  } else {
    for (const result of patchSidebarIconsAt(args[0])) {
      console.log(result.already ? 'already' : 'patched', result.file)
    }
  }
}
