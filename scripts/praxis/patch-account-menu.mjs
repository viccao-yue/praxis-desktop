#!/usr/bin/env node
/**
 * Praxis AccountMenu patch against shipped @deepseek-ai/dsh-client-ui-settings-account.
 *
 * Upstream shows 联系我们 / 登录 and uses signedOut as the collapsed label.
 * Praxis: drop contact + sign-in rows; unsigned label = settings; click opens settings.
 *
 * Usage:
 *   node scripts/praxis/patch-account-menu.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-account-menu.mjs --self-test
 */
import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-account-menu-patched */'

/** Apply Praxis AccountMenu behavior to a compiled settings-account client bundle. */
const UNSIGNED_ELLIPSIS = 'IconEllipsisOutlineMedium, { size: 14 }'
const UNSIGNED_GEAR = 'IconSettingsOutlineMedium, { size: 16 }'

/** Unsigned settings trigger uses a gear, not an ellipsis. */
function repairSettingsGlyph(source) {
  const menuStart = source.indexOf('function AccountMenu(')
  if (menuStart < 0 || !source.includes(UNSIGNED_ELLIPSIS)) return { source, changed: false }
  const menuEndMarker = source.indexOf('//#endregion', menuStart)
  const menuEnd = menuEndMarker > menuStart ? menuEndMarker : source.length
  const menu = source.slice(menuStart, menuEnd)
  if (!menu.includes(UNSIGNED_ELLIPSIS)) return { source, changed: false }
  return {
    source: source.slice(0, menuStart) + menu.replace(UNSIGNED_ELLIPSIS, UNSIGNED_GEAR) + source.slice(menuEnd),
    changed: true,
  }
}

export function patchAccountMenuSource(source) {
  if (source.includes(MARKER)) {
    const repaired = repairSettingsGlyph(source)
    return { source: repaired.source, changed: repaired.changed, already: !repaired.changed, steps: repaired.changed ? ['ellipsis→gear'] : undefined }
  }

  let next = source
  const steps = []

  // 0.1.x used signedOut; 0.2.1 AccountMenu uses "more" for the unsigned label.
  const labelPatterns = [
    'signedIn ? label : t("signedOut")',
    'signedIn ? label : t("more")',
  ]
  const labelHit = labelPatterns.find(pattern => next.includes(pattern))
  if (!labelHit) throw new Error('AccountMenu patch: unsigned label pattern missing (signedOut|more)')
  next = next.replaceAll(labelHit, 'signedIn ? label : t("settings")')
  steps.push(`label(${labelHit.includes('more') ? 'more' : 'signedOut'})→settings`)

  // Only rewrite the AccountMenu trigger toggle (first setOpen toggle inside AccountMenu).
  const menuStart = next.indexOf('function AccountMenu(')
  if (menuStart < 0) throw new Error('AccountMenu patch: function AccountMenu missing')
  const menuEndMarker = next.indexOf('//#endregion', menuStart)
  const menuEnd = menuEndMarker > menuStart ? menuEndMarker : next.length
  const before = next.slice(0, menuStart)
  let menu = next.slice(menuStart, menuEnd)
  const after = next.slice(menuEnd)

  const toggleRe = /onClick:\s*\(\)\s*=>\s*\{\s*setOpen\(\(value\)\s*=>\s*!value\);\s*\}/
  if (!toggleRe.test(menu)) throw new Error('AccountMenu patch: toggle onClick pattern missing in AccountMenu')
  menu = menu.replace(
    toggleRe,
    'onClick: () => { if (signedIn) setOpen((value) => !value); else openSettings(); }',
  )
  steps.push('click→openSettings')
  next = before + menu + after

  const contactBlock = /\{\s*id:\s*"contact",\s*label:\s*t\("contactUs"\),[\s\S]*?\},/
  if (!contactBlock.test(next)) throw new Error('AccountMenu patch: contact menu item missing')
  next = next.replace(contactBlock, '')
  steps.push('drop-contact')

  const signInBranch = /\.\.\.signedIn\s*\?\s*\[\{[\s\S]*?id:\s*"signout"[\s\S]*?\}\]\s*:\s*\[\{[\s\S]*?id:\s*"signin"[\s\S]*?\}\]/
  if (!signInBranch.test(next)) throw new Error('AccountMenu patch: signin/signout branch missing')
  next = next.replace(signInBranch, (match) => match.replace(/:\s*\[\{[\s\S]*?id:\s*"signin"[\s\S]*?\}\]/, ': []'))
  steps.push('drop-signin')

  next = next.replace(/\s*else if \(id === "contact"\) \{\s*setOpen\(false\);\s*contactUs\(\);\s*\}/g, '')
  next = next.replace(/\s*else if \(id === "signin"\) beginSignIn\(\);/g, '')
  next = next.replace(/,\s*contactUs(?=\s*,)/, '')
  next = next.replace(/const beginSignIn = \(\) => \{[\s\S]*?\};\n/, '')

  // Assert only inside AccountMenu — AccountSection may still show signedOut.
  const assertStart = next.indexOf('function AccountMenu(')
  const assertEnd = next.indexOf('//#endregion', assertStart)
  const menuBody = assertStart >= 0 && assertEnd > assertStart ? next.slice(assertStart, assertEnd) : next
  if (menuBody.includes('id: "contact"') || menuBody.includes('id: "signin"')) {
    throw new Error('AccountMenu patch: residual contact/signin markers remain in AccountMenu')
  }
  if (menuBody.includes('t("signedOut")') || /signedIn \? label : t\("more"\)/.test(menuBody)) {
    throw new Error('AccountMenu patch: residual unsigned label remain in AccountMenu')
  }
  if (!menuBody.includes('else openSettings()') && !menuBody.includes('else openSettings();')) {
    throw new Error('AccountMenu patch: openSettings click missing after transform')
  }

  next = MARKER + '\n' + next
  const repaired = repairSettingsGlyph(next)
  if (repaired.changed) steps.push('ellipsis→gear')
  return { source: repaired.source, changed: true, already: false, steps }
}

function resolveClientBundle(root) {
  try {
    return resolveProfilePackageFile(root, '@deepseek-ai/dsh-client-ui-settings-account', 'lib/client.js')
  } catch (cause) {
    throw new Error('AccountMenu patch: dsh-client-ui-settings-account client.js not found under ' + root, { cause })
  }
}

export function patchAccountMenuAt(root) {
  const file = resolveClientBundle(root)
  const before = readFileSync(file, 'utf8')
  const result = patchAccountMenuSource(before)
  if (result.changed) writeFileSync(file, result.source)
  return { file, ...result }
}

function selfTest() {
  const sample = `
		function AccountMenu({ wide, openSettings, openOnboarding, useAccount, signOut, contactUs, showLogin, start, cancel, t }) {
			const beginSignIn = () => {
				setOpen(false);
				start().catch(() => void 0);
			};
			return (0, react_jsx_runtime.jsxs)("div", {
				children: [
					(0, react_jsx_runtime.jsx)(Menu, {
						anchor: (0, react_jsx_runtime.jsxs)("button", {
							onClick: () => {
								setOpen((value) => !value);
							},
							children: [wide && (0, react_jsx_runtime.jsx)("span", {
								children: signedIn ? label : t("more")
							})]
						}),
						items: [
							{ id: "settings", label: t("settings") },
							{
								id: "contact",
								label: t("contactUs"),
								icon: (0, react_jsx_runtime.jsx)(Icon, { size: 16 })
							},
							...signedIn ? [{
								id: "signout",
								label: t("signOut"),
								disabled: busy
							}] : [{
								id: "signin",
								label: t("signIn"),
								icon: (0, react_jsx_runtime.jsx)(Icon, { size: 16 })
							}]
						],
						onSelect: (id) => {
							if (id === "settings") {
								setOpen(false);
								openSettings();
							} else if (id === "contact") {
								setOpen(false);
								contactUs();
							} else if (id === "signin") beginSignIn();
							else logout();
						}
					})
				]
			});
		}
		//#endregion
`
  const once = patchAccountMenuSource(sample)
  if (!once.changed) throw new Error('self-test: expected change')
  const twice = patchAccountMenuSource(once.source)
  if (!twice.already) throw new Error('self-test: expected idempotent skip')
  if (once.source.includes('id: "contact"')) throw new Error('self-test: contact row still present')
  if (!once.source.includes('signedIn ? label : t("settings")')) throw new Error('self-test: settings label missing')
  if (!once.source.includes('else openSettings()')) throw new Error('self-test: openSettings click missing')
  console.log('patch-account-menu self-test ok:', once.steps.join(', '))
}

const isMain = process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const args = process.argv.slice(2)
  if (args[0] === '--self-test') {
    selfTest()
  } else if (!args[0]) {
    console.error('Usage: node scripts/praxis/patch-account-menu.mjs <profile-or-package-root> | --self-test')
    process.exit(2)
  } else {
    const result = patchAccountMenuAt(args[0])
    console.log(result.already ? 'AccountMenu already patched:' : 'AccountMenu patched:', result.file)
    if (result.steps) console.log('steps:', result.steps.join(', '))
  }
}
