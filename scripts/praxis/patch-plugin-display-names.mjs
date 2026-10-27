#!/usr/bin/env node
/**
 * Praxis: hide technical `workdsh-` prefixes in plugin manager UI (personal + enterprise).
 *
 * Usage:
 *   node scripts/praxis/patch-plugin-display-names.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-plugin-display-names.mjs --self-test
 */
import { existsSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const MARKER = '/* praxis-plugin-display-names-patched */'
const BUNDLE = '@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js'
const PNPM_PREFIX = '@deepseek-ai+dsh-client-ui-plugin-manager@'

export function praxisUiPluginLabel(text) {
  return typeof text === 'string' ? text.replace(/workdsh-/g, '') : text
}

const BROKEN_BLOCK = `\t\tfunction shortName(name) {
\t\t\treturn (name.startsWith("@") ? name.slice(name.indexOf("/") + 1) : name).replace(/^dsh-(?:host-|client-)?/, "");

\t\tfunction praxisUiPluginLabel(text) {
\t\t\treturn typeof text === "string" ? text.replace(/workdsh-/g, "") : text;
\t\t}\t\t}`

const FIXED_BLOCK = `\t\tfunction shortName(name) {
\t\t\treturn (name.startsWith("@") ? name.slice(name.indexOf("/") + 1) : name).replace(/^dsh-(?:host-|client-)?/, "");
\t\t}
\t\tfunction praxisUiPluginLabel(text) {
\t\t\treturn typeof text === "string" ? text.replace(/workdsh-/g, "") : text;
\t\t}`

const REPLACEMENTS = [
  {
    from: 'title: pkg.meta?.title === void 0 ? pkg.name : resolveText(pkg.meta.title),',
    to: 'title: praxisUiPluginLabel(pkg.meta?.title === void 0 ? pkg.name : resolveText(pkg.meta.title)),',
  },
  {
    from: 'title: row.meta?.title === void 0 ? row.moduleName : resolveText(row.meta.title),',
    to: 'title: praxisUiPluginLabel(row.meta?.title === void 0 ? row.moduleName : resolveText(row.meta.title)),',
  },
  {
    from: 'children: row.moduleName',
    to: 'children: praxisUiPluginLabel(row.moduleName)',
  },
  {
    from: 'children: (0, react_jsx_runtime.jsx)("code", { children: row.moduleName })',
    to: 'children: (0, react_jsx_runtime.jsx)("code", { children: praxisUiPluginLabel(row.moduleName) })',
  },
  {
    from: 'children: pkg.name',
    to: 'children: praxisUiPluginLabel(pkg.name)',
  },
]

export function patchPluginDisplayNamesSource(source) {
  let next = source.includes(MARKER) ? source : MARKER + '\n' + source
  if (next.includes(BROKEN_BLOCK)) {
    next = next.replace(BROKEN_BLOCK, FIXED_BLOCK)
    return { source: next, changed: true, already: false, steps: ['repair-shortName-scope'] }
  }
  if (next.includes(FIXED_BLOCK) && REPLACEMENTS.every(({ from, to }) => next.includes(to) || !next.includes(from))) {
    return { source: next, changed: false, already: true }
  }
  const insertNeedle = '\t\tfunction shortName(name) {\n\t\t\treturn (name.startsWith("@") ? name.slice(name.indexOf("/") + 1) : name).replace(/^dsh-(?:host-|client-)?/, "");\n\t\t}'
  if (!next.includes('function praxisUiPluginLabel(')) {
    if (!next.includes(insertNeedle)) throw new Error('Plugin display patch: shortName() block missing')
    next = next.replace(insertNeedle, FIXED_BLOCK)
  }
  const steps = []
  for (const { from, to } of REPLACEMENTS) {
    if (!next.includes(from)) {
      if (next.includes(to)) continue
      throw new Error('Plugin display patch: pattern missing: ' + from.slice(0, 60))
    }
    next = next.replace(from, to)
    steps.push(from.slice(0, 24))
  }
  return { source: next, changed: true, already: false, steps }
}

function resolveBundle(root) {
  const direct = join(root, 'node_modules', BUNDLE)
  if (existsSync(direct)) return realpathSync(direct)
  const pnpm = join(root, 'node_modules/.pnpm')
  if (existsSync(pnpm)) {
    for (const entry of readdirSync(pnpm)) {
      if (!entry.includes('dsh-client-ui-plugin-manager')) continue
      const path = join(pnpm, entry, 'node_modules', BUNDLE)
      if (existsSync(path)) return realpathSync(path)
    }
  }
  throw new Error('Plugin display patch: missing ' + BUNDLE)
}

export function patchPluginDisplayNamesAt(root) {
  const targets = new Set()
  targets.add(resolveBundle(root))
  const pnpm = join(root, 'node_modules/.pnpm')
  if (existsSync(pnpm)) {
    for (const entry of readdirSync(pnpm)) {
      if (!entry.includes('dsh-client-ui-plugin-manager')) continue
      const path = join(pnpm, entry, 'node_modules', BUNDLE)
      if (existsSync(path)) targets.add(realpathSync(path))
    }
  }
  const results = []
  for (const file of targets) {
    const before = readFileSync(file, 'utf8')
    const result = patchPluginDisplayNamesSource(before)
    if (result.changed) writeFileSync(file, result.source)
    results.push({ file, ...result })
  }
  return results
}

function selfTest() {
  if (praxisUiPluginLabel('workdsh-enterprise-connection') !== 'enterprise-connection') {
    throw new Error('self-test: strip failed')
  }
  console.log('patch-plugin-display-names self-test ok')
}

const isMain = process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const args = process.argv.slice(2)
  if (args[0] === '--self-test') selfTest()
  else if (!args[0]) {
    console.error('Usage: node scripts/praxis/patch-plugin-display-names.mjs <profile-or-package-root> | --self-test')
    process.exit(2)
  } else {
    for (const result of patchPluginDisplayNamesAt(args[0])) {
      console.log(result.already ? 'already' : 'patched', result.file)
    }
  }
}
