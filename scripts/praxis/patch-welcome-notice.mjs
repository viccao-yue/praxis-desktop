#!/usr/bin/env node
/**
 * Hide the upstream DeepSeek 「预览版说明」WelcomeNotice on first launch.
 *
 * Usage:
 *   node scripts/praxis/patch-welcome-notice.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-welcome-notice.mjs --self-test
 */
import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-welcome-notice-hidden */'
const HEAD = 'function WelcomeNotice(props) {'
const HIDE = `${HEAD}\n\t\t\treturn null;`

/** Hide WelcomeNotice so Desktop never blocks on the preview disclaimer. */
export function patchWelcomeNoticeSource(source) {
  if (source.includes(MARKER)) return { source, changed: false, already: true }
  if (!source.includes(HEAD)) throw new Error('Welcome notice patch: function WelcomeNotice missing')
  if (source.includes(HIDE)) {
    return { source: MARKER + '\n' + source, changed: true, already: false, steps: ['mark-already-null'] }
  }
  const next = source.replace(HEAD, HIDE)
  if (!next.includes(HIDE)) throw new Error('Welcome notice patch: WelcomeNotice still visible after transform')
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
  const sample = `${HEAD}
			const { complete, controller, useWelcome, t } = props;
			return (0, react_jsx_runtime.jsxs)(OnboardingModal, { title: t("welcomeTitle") });
		}`
  const once = patchWelcomeNoticeSource(sample)
  if (!once.changed || !once.source.includes(HIDE)) throw new Error('self-test: expected hide')
  const twice = patchWelcomeNoticeSource(once.source)
  if (!twice.already) throw new Error('self-test: expected idempotent skip')
  console.log('patch-welcome-notice self-test ok:', once.steps.join(', '))
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
