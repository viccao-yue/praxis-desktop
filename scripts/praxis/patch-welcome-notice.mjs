#!/usr/bin/env node
/**
 * Hide the upstream DeepSeek 「预览版说明」WelcomeNotice on first launch.
 *
 * Supports both pretty (0.2.1) and compact (0.2.2+) compiled bundles.
 *
 * Usage:
 *   node scripts/praxis/patch-welcome-notice.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-welcome-notice.mjs --self-test
 */
import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-welcome-notice-hidden */'
const HEAD_PRETTY = 'function WelcomeNotice(props) {'
const HIDE_PRETTY = `${HEAD_PRETTY}\n\t\t\treturn null;`
const HEAD_COMPACT = 'function WelcomeNotice(props){'
const HIDE_COMPACT = `${HEAD_COMPACT}return null;`

/** Hide WelcomeNotice so Desktop never blocks on the preview disclaimer. */
export function patchWelcomeNoticeSource(source) {
  if (source.includes(MARKER)) return { source, changed: false, already: true }
  const compact = source.includes(HEAD_COMPACT)
  const head = compact ? HEAD_COMPACT : HEAD_PRETTY
  const hide = compact ? HIDE_COMPACT : HIDE_PRETTY
  if (!source.includes(head)) throw new Error('Welcome notice patch: function WelcomeNotice missing')
  if (source.includes(hide)) {
    return { source: MARKER + '\n' + source, changed: true, already: false, steps: ['mark-already-null'] }
  }
  const next = source.replace(head, hide)
  if (!next.includes(hide)) throw new Error('Welcome notice patch: WelcomeNotice still visible after transform')
  return { source: MARKER + '\n' + next, changed: true, already: false, steps: ['hide-WelcomeNotice'] }
}

function resolveClientBundle(root) {
  try {
    return resolveProfilePackageFile(root, '@deepseek-ai/dsh-client-ui-settings-models', 'lib/client.js')
  } catch (cause) {
    throw new Error('Welcome notice patch: dsh-client-ui-settings-models client.js not found under ' + root, { cause })
  }
}

export function patchWelcomeNoticeAt(root) {
  const file = resolveClientBundle(root)
  const before = readFileSync(file, 'utf8')
  const result = patchWelcomeNoticeSource(before)
  if (result.changed) writeFileSync(file, result.source)
  return { file, ...result }
}

function selfTest() {
  const sample = `${HEAD_PRETTY}
			const { complete, controller, useWelcome, t } = props;
			return (0, react_jsx_runtime.jsxs)(OnboardingModal, { title: t("welcomeTitle") });
		}`
  const once = patchWelcomeNoticeSource(sample)
  if (!once.changed || !once.source.includes(HIDE_PRETTY)) throw new Error('self-test: expected hide')
  const twice = patchWelcomeNoticeSource(once.source)
  if (!twice.already) throw new Error('self-test: expected idempotent skip')
  const compact = `${HEAD_COMPACT}const{complete,controller,useWelcome,t}=props;return(0,react_jsx_runtime.jsxs)(OnboardingModal,{title:t(\`welcomeTitle\`)})}`
  const compactOnce = patchWelcomeNoticeSource(compact)
  if (!compactOnce.changed || !compactOnce.source.includes(HIDE_COMPACT)) throw new Error('self-test compact: expected hide')
  console.log('patch-welcome-notice self-test ok:', once.steps.join(', '), '| compact:', compactOnce.steps.join(', '))
}

const isMain = process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const args = process.argv.slice(2)
  if (args[0] === '--self-test') selfTest()
  else if (!args[0]) {
    console.error('Usage: node scripts/praxis/patch-welcome-notice.mjs <profile-or-package-root> | --self-test')
    process.exit(2)
  } else {
    const result = patchWelcomeNoticeAt(args[0])
    console.log(result.already ? 'Welcome notice already hidden:' : 'Welcome notice hidden:', result.file)
  }
}
