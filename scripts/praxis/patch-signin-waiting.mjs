#!/usr/bin/env node
/**
 * Hide the upstream DeepSeek "开始使用 / 等待登录" SignInDialog for first-run
 * and manual login prompts. Personal and enterprise profiles share this client.
 * Account onboarding skips the forced sign-in step so the flow is not blocked;
 * users can still sign in later from Settings.
 *
 * Usage:
 *   node scripts/praxis/patch-signin-waiting.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-signin-waiting.mjs --self-test
 */
import { existsSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const MARKER = '/* praxis-signin-dialog-hidden */'
const OLD_MARKER = '/* praxis-signin-waiting-hidden */'

const SIGNIN_HEAD = 'function SignInDialog({ account, colorScheme, start, cancel, close, useApiKey, t }) {'
const SIGNIN_HIDE = `${SIGNIN_HEAD}\n\t\t\treturn null;`

const ONBOARDING_BLOCK = `(0, react.useEffect)(() => {
				if (account.view?.status === "credential-stored") complete();
			}, [account.view?.status, complete]);
			if (!account.view || account.view.status === "credential-stored") return null;
			return (0, react_jsx_runtime.jsx)(SignInDialog, {
				account,
				colorScheme,
				start,
				cancel,
				t,
				close: () => {
					showLogin(false);
					complete();
				},
				useApiKey: () => {
					showLogin(false);
					useApiKey();
				}
			});`

const ONBOARDING_SKIP = `(0, react.useEffect)(() => {
				if (!account.view) return;
				showLogin(false);
				complete();
			}, [account.view, complete, showLogin]);
			return null;`

/** Hide SignInDialog and skip forced account onboarding sign-in. */
export function patchSignInWaitingSource(source) {
  if (source.includes(MARKER)) return { source, changed: false, already: true }

  let next = source.replaceAll(OLD_MARKER + '\n', '').replaceAll(OLD_MARKER, '')
  const steps = []

  if (!next.includes(SIGNIN_HEAD)) {
    throw new Error('SignIn dialog patch: function SignInDialog missing')
  }

  if (!next.includes('return null;\n\t\t\tconst [busy, setBusy]')) {
    // Drop the older waiting-only early return if present, then hide the whole dialog.
    next = next.replace(
      'const title = error ? t("failureTitle") : active ? t("browserTitle") : expired ? t("timeoutTitle") : t("loginTitle");\n\t\t\tif (waiting) return null;\n\t\t\treturn (0, react_jsx_runtime.jsxs)(_deepseek_ai_dsh_client_ui_primitives.Modal, {',
      'const title = error ? t("failureTitle") : active ? t("browserTitle") : expired ? t("timeoutTitle") : t("loginTitle");\n\t\t\treturn (0, react_jsx_runtime.jsxs)(_deepseek_ai_dsh_client_ui_primitives.Modal, {',
    )
    next = next.replace(SIGNIN_HEAD, SIGNIN_HIDE)
    steps.push('hide-SignInDialog')
  } else {
    steps.push('SignInDialog-already-null')
  }

  if (!next.includes(ONBOARDING_SKIP)) {
    if (!next.includes(ONBOARDING_BLOCK)) {
      throw new Error('SignIn dialog patch: AccountOnboarding SignInDialog block missing')
    }
    next = next.replace(ONBOARDING_BLOCK, ONBOARDING_SKIP)
    steps.push('skip-AccountOnboarding')
  } else {
    steps.push('AccountOnboarding-already-skipped')
  }

  if (!next.includes('function SignInDialog({ account, colorScheme, start, cancel, close, useApiKey, t }) {\n\t\t\treturn null;')) {
    throw new Error('SignIn dialog patch: SignInDialog still visible after transform')
  }
  if (next.includes('return (0, react_jsx_runtime.jsx)(SignInDialog, {')) {
    throw new Error('SignIn dialog patch: AccountOnboarding still mounts SignInDialog')
  }

  return { source: MARKER + '\n' + next, changed: true, already: false, steps }
}

function resolveClientBundle(root) {
  const candidates = [
    join(root, 'node_modules/@deepseek-ai/dsh-client-ui-settings-account/lib/client.js'),
    join(root, 'lib/client.js'),
    join(root, 'client.js'),
  ]
  for (const path of candidates) {
    if (existsSync(path)) return realpathSync(path)
  }
  const pnpm = join(root, 'node_modules/.pnpm')
  if (existsSync(pnpm)) {
    for (const entry of readdirSync(pnpm)) {
      if (!entry.startsWith('@deepseek-ai+dsh-client-ui-settings-account@')) continue
      const path = join(pnpm, entry, 'node_modules/@deepseek-ai/dsh-client-ui-settings-account/lib/client.js')
      if (existsSync(path)) return realpathSync(path)
    }
  }
  throw new Error('SignIn dialog patch: dsh-client-ui-settings-account client.js not found under ' + root)
}

export function patchSignInWaitingAt(root) {
  const file = resolveClientBundle(root)
  const before = readFileSync(file, 'utf8')
  const result = patchSignInWaitingSource(before)
  if (result.changed) writeFileSync(file, result.source)
  return { file, ...result }
}

function selfTest() {
  const sample = `
		function SignInDialog({ account, colorScheme, start, cancel, close, useApiKey, t }) {
			const waiting = active && !error;
			const title = error ? t("failureTitle") : active ? t("browserTitle") : expired ? t("timeoutTitle") : t("loginTitle");
			if (waiting) return null;
			return (0, react_jsx_runtime.jsxs)(_deepseek_ai_dsh_client_ui_primitives.Modal, { open: true, title });
		}
		function AccountOnboarding({ complete, useApiKey, useAccount, useTheme, setOnboarding, showLogin, start, cancel, t }) {
			const account = useAccount((value) => value);
			const colorScheme = useTheme((snapshot) => snapshot.active.colorScheme);
			(0, react.useEffect)(() => {
				setOnboarding(true);
				return () => {
					setOnboarding(false);
				};
			}, [setOnboarding]);
			(0, react.useEffect)(() => {
				if (account.view?.status === "credential-stored") complete();
			}, [account.view?.status, complete]);
			if (!account.view || account.view.status === "credential-stored") return null;
			return (0, react_jsx_runtime.jsx)(SignInDialog, {
				account,
				colorScheme,
				start,
				cancel,
				t,
				close: () => {
					showLogin(false);
					complete();
				},
				useApiKey: () => {
					showLogin(false);
					useApiKey();
				}
			});
		}
`
  const once = patchSignInWaitingSource(sample)
  if (!once.changed) throw new Error('self-test: expected change')
  if (!once.source.includes('function SignInDialog({ account, colorScheme, start, cancel, close, useApiKey, t }) {\n\t\t\treturn null;')) {
    throw new Error('self-test: SignInDialog not hidden')
  }
  if (once.source.includes('return (0, react_jsx_runtime.jsx)(SignInDialog, {')) {
    throw new Error('self-test: AccountOnboarding still mounts dialog')
  }
  const twice = patchSignInWaitingSource(once.source)
  if (!twice.already) throw new Error('self-test: expected idempotent skip')
  console.log('patch-signin-waiting self-test ok:', once.steps.join(', '))
}

const isMain = process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const args = process.argv.slice(2)
  if (args[0] === '--self-test') {
    selfTest()
  } else if (!args[0]) {
    console.error('Usage: node scripts/praxis/patch-signin-waiting.mjs <profile-or-package-root> | --self-test')
    process.exit(2)
  } else {
    const result = patchSignInWaitingAt(args[0])
    console.log(result.already ? 'SignIn dialog already patched:' : 'SignIn dialog patched:', result.file)
    if (result.steps) console.log('steps:', result.steps.join(', '))
  }
}
