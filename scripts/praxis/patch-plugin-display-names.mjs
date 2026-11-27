#!/usr/bin/env node
/**
 * Praxis: hide technical `workdsh-` prefixes in plugin manager UI (personal + enterprise).
 *
 * Supports both pretty (0.2.1) and compact (0.2.2+) compiled bundles.
 *
 * Usage:
 *   node scripts/praxis/patch-plugin-display-names.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-plugin-display-names.mjs --self-test
 */
import { existsSync, globSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-plugin-display-names-patched */'
const PACKAGE_NAME = '@deepseek-ai/dsh-client-ui-plugin-manager'
const BUNDLE = PACKAGE_NAME + '/lib/client.js'

export function praxisUiPluginLabel(text) {
  return typeof text === 'string' ? text.replace(/workdsh-/g, '') : text
}

const BROKEN_BLOCK = `\t\tfunction shortName(name) {
\t\t\treturn (name.startsWith("@") ? name.slice(name.indexOf("/") + 1) : name).replace(/^dsh-(?:host-|client-)?/, "");

\t\tfunction praxisUiPluginLabel(text) {
\t\t\treturn typeof text === "string" ? text.replace(/workdsh-/g, "") : text;
\t\t}\t\t}`

const FIXED_BLOCK_PRETTY = `\t\tfunction shortName(name) {
\t\t\treturn (name.startsWith("@") ? name.slice(name.indexOf("/") + 1) : name).replace(/^dsh-(?:host-|client-)?/, "");
\t\t}
\t\tfunction praxisUiPluginLabel(text) {
\t\t\treturn typeof text === "string" ? text.replace(/workdsh-/g, "") : text;
\t\t}`

const INSERT_NEEDLE_PRETTY = '\t\tfunction shortName(name) {\n\t\t\treturn (name.startsWith("@") ? name.slice(name.indexOf("/") + 1) : name).replace(/^dsh-(?:host-|client-)?/, "");\n\t\t}'

const INSERT_NEEDLE_COMPACT = 'function shortName(name){return(name.startsWith(`@`)?name.slice(name.indexOf(`/`)+1):name).replace(/^dsh-(?:host-|client-)?/,``)}'
const FIXED_BLOCK_COMPACT = `${INSERT_NEEDLE_COMPACT}function praxisUiPluginLabel(text){return typeof text===\`string\`?text.replace(/workdsh-/g,\`\`):text}`

const REPLACEMENTS_PRETTY = [
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

const REPLACEMENTS_COMPACT = [
  {
    from: 'title:pkg.meta?.title===void 0?pkg.name:resolveText(pkg.meta.title),',
    to: 'title:praxisUiPluginLabel(pkg.meta?.title===void 0?pkg.name:resolveText(pkg.meta.title)),',
  },
  {
    from: 'title:row.meta?.title===void 0?row.moduleName:resolveText(row.meta.title),',
    to: 'title:praxisUiPluginLabel(row.meta?.title===void 0?row.moduleName:resolveText(row.meta.title)),',
  },
  {
    from: 'children:row.moduleName',
    to: 'children:praxisUiPluginLabel(row.moduleName)',
  },
  {
    from: 'children:(0,react_jsx_runtime.jsx)(`code`,{children:row.moduleName})',
    to: 'children:(0,react_jsx_runtime.jsx)(`code`,{children:praxisUiPluginLabel(row.moduleName)})',
  },
  {
    from: 'children:pkg.name',
    to: 'children:praxisUiPluginLabel(pkg.name)',
  },
]

export function patchPluginDisplayNamesSource(source) {
  let next = source.includes(MARKER) ? source : MARKER + '\n' + source
  if (next.includes(BROKEN_BLOCK)) {
    next = next.replace(BROKEN_BLOCK, FIXED_BLOCK_PRETTY)
    return { source: next, changed: true, already: false, steps: ['repair-shortName-scope'] }
  }
  const compact = next.includes(INSERT_NEEDLE_COMPACT) || next.includes('function shortName(name){return(name.startsWith(`@`)')
  const fixed = compact ? FIXED_BLOCK_COMPACT : FIXED_BLOCK_PRETTY
  const insertNeedle = compact ? INSERT_NEEDLE_COMPACT : INSERT_NEEDLE_PRETTY
  const replacements = compact ? REPLACEMENTS_COMPACT : REPLACEMENTS_PRETTY

  if (next.includes(fixed) && replacements.every(({ from, to }) => next.includes(to) || !next.includes(from))) {
    return { source: next, changed: false, already: true }
  }
  if (!next.includes('function praxisUiPluginLabel(')) {
    if (!next.includes(insertNeedle)) throw new Error('Plugin display patch: shortName() block missing')
    next = next.replace(insertNeedle, fixed)
  }
  const steps = []
  for (const { from, to } of replacements) {
    if (!next.includes(from)) {
      if (next.includes(to)) continue
      throw new Error('Plugin display patch: pattern missing: ' + from.slice(0, 60))
    }
    next = next.replaceAll(from, to)
    steps.push(from.slice(0, 24))
  }
  return { source: next, changed: true, already: false, steps }
}

function resolveBundle(root) {
  try {
    return resolveProfilePackageFile(root, PACKAGE_NAME, 'lib/client.js')
  } catch (cause) {
    throw new Error('Plugin display patch: missing ' + BUNDLE, { cause })
  }
}

export function patchPluginDisplayNamesAt(root) {
  const targets = new Set()
  targets.add(resolveBundle(root))
  for (const match of globSync(`**/node_modules/${PACKAGE_NAME}/lib/client.js`, {
    cwd: resolve(root),
    absolute: true,
    nodir: true,
  })) {
    if (existsSync(match)) targets.add(realpathSync(match))
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
  const pretty = `${INSERT_NEEDLE_PRETTY}
\t\tfunction packageText(pkg, resolveText) {
\t\t\treturn {
\t\t\t\ttitle: pkg.meta?.title === void 0 ? pkg.name : resolveText(pkg.meta.title),
\t\t\t};
\t\t}
\t\tfunction rowText(row, resolveText) {
\t\t\treturn {
\t\t\t\ttitle: row.meta?.title === void 0 ? row.moduleName : resolveText(row.meta.title),
\t\t\t};
\t\t}
\t\tchildren: row.moduleName
\t\tchildren: (0, react_jsx_runtime.jsx)("code", { children: row.moduleName })
\t\tchildren: pkg.name`
  const once = patchPluginDisplayNamesSource(pretty)
  if (!once.changed || !once.source.includes('praxisUiPluginLabel(pkg.name)')) throw new Error('self-test pretty failed')
  const compact = `${INSERT_NEEDLE_COMPACT}function packageText(pkg,resolveText){return{title:pkg.meta?.title===void 0?pkg.name:resolveText(pkg.meta.title),description:void 0}}function rowText(row,resolveText){return{title:row.meta?.title===void 0?row.moduleName:resolveText(row.meta.title),description:void 0}}const x={children:row.moduleName};const y={children:(0,react_jsx_runtime.jsx)(\`code\`,{children:row.moduleName})};const z={"data-plugin-name":true,children:pkg.name}`
  const compactOnce = patchPluginDisplayNamesSource(compact)
  if (!compactOnce.changed || !compactOnce.source.includes('praxisUiPluginLabel(pkg.name)')) throw new Error('self-test compact failed')
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
