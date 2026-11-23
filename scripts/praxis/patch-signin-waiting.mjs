#!/usr/bin/env node
/**
 * Hide the upstream DeepSeek "开始使用 / 等待登录" SignInDialog for first-run
 * and manual login prompts. Personal and enterprise profiles share this client.
 * Account onboarding skips the forced sign-in step so the flow is not blocked;
 * users can still sign in later from Settings.
 *
 * Supports both pretty (0.2.1) and compact backtick (0.2.2+) compiled bundles.
 *
 * Usage:
 *   node scripts/praxis/patch-signin-waiting.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-signin-waiting.mjs --self-test
 */
import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-signin-dialog-hidden */'
const OLD_MARKER = '/* praxis-signin-waiting-hidden */'

const SIGNIN_HEAD_PRETTY = 'function SignInDialog({ account, colorScheme, start, cancel, close, useApiKey, t }) {'
const SIGNIN_HIDE_PRETTY = `${SIGNIN_HEAD_PRETTY}\n\t\t\treturn null;`
const SIGNIN_HEAD_COMPACT = 'function SignInDialog({account,colorScheme,start,cancel,close,useApiKey,t}){'
const SIGNIN_HIDE_COMPACT = `${SIGNIN_HEAD_COMPACT}return null;`

const ONBOARDING_BLOCK_PRETTY = `(0, react.useEffect)(() => {
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

const ONBOARDING_SKIP_PRETTY = `(0, react.useEffect)(() => {
				if (!account.view) return;
				showLogin(false);
				complete();
			}, [account.view, complete, showLogin]);
			return null;`

const ONBOARDING_BLOCK_COMPACT = `(0,react.useEffect)(()=>{if(account.view?.status===\`credential-stored\`)complete()},[account.view?.status,complete]);if(!account.view||account.view.status===\`credential-stored\`)return null;return(0,react_jsx_runtime.jsx)(SignInDialog,{account,colorScheme,start,cancel,t,close:()=>{showLogin(false);complete()},useApiKey:()=>{showLogin(false);useApiKey()}})`

const ONBOARDING_SKIP_COMPACT = `(0,react.useEffect)(()=>{if(!account.view)return;showLogin(false);complete()},[account.view,complete,showLogin]);return null`

/** Hide SignInDialog and skip forced account onboarding sign-in. */
export function patchSignInWaitingSource(source) {
  if (source.includes(MARKER)) return { source, changed: false, already: true }

  let next = source.replaceAll(OLD_MARKER + '\n', '').replaceAll(OLD_MARKER, '')
  const steps = []
  const compact = next.includes(SIGNIN_HEAD_COMPACT)

  const head = compact ? SIGNIN_HEAD_COMPACT : SIGNIN_HEAD_PRETTY
  const hide = compact ? SIGNIN_HIDE_COMPACT : SIGNIN_HIDE_PRETTY
  if (!next.includes(head)) {
    throw new Error('SignIn dialog patch: function SignInDialog missing')
  }

  const alreadyNullPretty = next.includes('return null;\n\t\t\tconst [busy, setBusy]')
  const alreadyNullCompact = next.includes(SIGNIN_HIDE_COMPACT)
  if (alreadyNullPretty || alreadyNullCompact) {
    steps.push('SignInDialog-already-null')
  } else {
    // Drop the older waiting-only early return if present, then hide the whole dialog.
    next = next.replace(
      'const title = error ? t("failureTitle") : active ? t("browserTitle") : expired ? t("timeoutTitle") : t("loginTitle");\n\t\t\tif (waiting) return null;\n\t\t\treturn (0, react_jsx_runtime.jsxs)(_deepseek_ai_dsh_client_ui_primitives.Modal, {',
      'const title = error ? t("failureTitle") : active ? t("browserTitle") : expired ? t("timeoutTitle") : t("loginTitle");\n\t\t\treturn (0, react_jsx_runtime.jsxs)(_deepseek_ai_dsh_client_ui_primitives.Modal, {',
    )
    next = next.replace(head, hide)
    steps.push('hide-SignInDialog')
  }

  const skip = compact ? ONBOARDING_SKIP_COMPACT : ONBOARDING_SKIP_PRETTY
  const block = compact ? ONBOARDING_BLOCK_COMPACT : ONBOARDING_BLOCK_PRETTY
  if (!next.includes(skip)) {
    if (!next.includes(block)) {
      throw new Error('SignIn dialog patch: AccountOnboarding SignInDialog block missing')
    }
    next = next.replace(block, skip)
    steps.push('skip-AccountOnboarding')
  } else {
    steps.push('AccountOnboarding-already-skipped')
  }

  if (!next.includes(hide) && !alreadyNullPretty) {
    throw new Error('SignIn dialog patch: SignInDialog still visible after transform')
  }
  if (next.includes('return (0, react_jsx_runtime.jsx)(SignInDialog, {') || next.includes('return(0,react_jsx_runtime.jsx)(SignInDialog,{')) {
    throw new Error('SignIn dialog patch: AccountOnboarding still mounts SignInDialog')
  }

  return { source: MARKER + '\n' + next, changed: true, already: false, steps }
}

function resolveClientBundle(root) {
  try {
    return resolveProfilePackageFile(root, '@deepseek-ai/dsh-client-ui-settings-account', 'lib/client.js')
  } catch (cause) {
    throw new Error('SignIn dialog patch: dsh-client-ui-settings-account client.js not found under ' + root, { cause })
  }
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
  if (!once.source.includes(SIGNIN_HIDE_PRETTY)) throw new Error('self-test: SignInDialog not hidden')
  if (once.source.includes('return (0, react_jsx_runtime.jsx)(SignInDialog, {')) throw new Error('self-test: onboarding still mounts')
  const twice = patchSignInWaitingSource(once.source)
  if (!twice.already) throw new Error('self-test: expected idempotent skip')

  const compact = `function SignInDialog({account,colorScheme,start,cancel,close,useApiKey,t}){const[busy,setBusy]=(0,react.useState)(false);return(0,react_jsx_runtime.jsxs)(Modal,{open:true})}function AccountOnboarding({complete,useApiKey,useAccount,useTheme,setOnboarding,showLogin,start,cancel,t}){const account=useAccount(value=>value);const colorScheme=useTheme(snapshot=>snapshot.active.colorScheme);(0,react.useEffect)(()=>{setOnboarding(true);return()=>{setOnboarding(false)}},[setOnboarding]);(0,react.useEffect)(()=>{if(account.view?.status===\`credential-stored\`)complete()},[account.view?.status,complete]);if(!account.view||account.view.status===\`credential-stored\`)return null;return(0,react_jsx_runtime.jsx)(SignInDialog,{account,colorScheme,start,cancel,t,close:()=>{showLogin(false);complete()},useApiKey:()=>{showLogin(false);useApiKey()}})}`
  const compactOnce = patchSignInWaitingSource(compact)
  if (!compactOnce.changed || !compactOnce.source.includes(SIGNIN_HIDE_COMPACT)) throw new Error('self-test compact: hide failed')
  if (compactOnce.source.includes('return(0,react_jsx_runtime.jsx)(SignInDialog,{')) throw new Error('self-test compact: onboarding still mounts')
  console.log('patch-signin-waiting self-test ok:', once.steps.join(', '), '| compact:', compactOnce.steps.join(', '))
}

const isMain = process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const args = process.argv.slice(2)
  if (args[0] === '--self-test') selfTest()
  else if (!args[0]) {
    console.error('Usage: node scripts/praxis/patch-signin-waiting.mjs <profile-or-package-root> | --self-test')
    process.exit(2)
  } else {
    const result = patchSignInWaitingAt(args[0])
    console.log(result.already ? 'SignIn dialog already hidden:' : 'SignIn dialog hidden:', result.file)
    if (result.steps) console.log('steps:', result.steps.join(', '))
  }
}
