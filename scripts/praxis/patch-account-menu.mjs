#!/usr/bin/env node
/**
 * Praxis AccountMenu patch against shipped @deepseek-ai/dsh-client-ui-settings-account.
 *
 * Upstream shows 联系我们 / 登录 and uses signedOut/more as the collapsed label.
 * Praxis: drop contact + sign-in rows; unsigned label = settings; click opens settings.
 *
 * Supports both pretty (0.2.1) and compact backtick (0.2.2+) compiled bundles.
 *
 * Usage:
 *   node scripts/praxis/patch-account-menu.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-account-menu.mjs --self-test
 */
import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { resolveProfilePackageFile } from './resolve-profile-module.mjs'

const MARKER = '/* praxis-account-menu-patched */'

const UNSIGNED_ELLIPSIS_PRETTY = 'IconEllipsisOutlineMedium, { size: 14 }'
const UNSIGNED_GEAR_PRETTY = 'IconSettingsOutlineMedium, { size: 16 }'
const UNSIGNED_ELLIPSIS_COMPACT = 'IconEllipsisOutlineMedium,{size:14}'
const UNSIGNED_GEAR_COMPACT = 'IconSettingsOutlineMedium,{size:16}'

/** Locate the compiled AccountMenu function body (pretty or compact). */
function accountMenuRange(source) {
  const menuStart = source.indexOf('function AccountMenu(')
  if (menuStart < 0) return null
  const regionEnd = source.indexOf('//#endregion', menuStart)
  if (regionEnd > menuStart) return { menuStart, menuEnd: regionEnd }
  // Skip the parameter list (which may itself use object destructuring braces).
  const paramsOpen = source.indexOf('(', menuStart)
  let depth = 0
  let paramsClose = -1
  for (let i = paramsOpen; i < source.length; i++) {
    const c = source[i]
    if (c === '(') depth++
    else if (c === ')') {
      depth--
      if (depth === 0) {
        paramsClose = i
        break
      }
    }
  }
  if (paramsClose < 0) return { menuStart, menuEnd: source.length }
  const brace = source.indexOf('{', paramsClose)
  if (brace < 0) return { menuStart, menuEnd: source.length }
  depth = 0
  for (let i = brace; i < source.length; i++) {
    const c = source[i]
    if (c === '{') depth++
    else if (c === '}') {
      depth--
      if (depth === 0) return { menuStart, menuEnd: i + 1 }
    }
  }
  return { menuStart, menuEnd: source.length }
}

/** Unsigned settings trigger uses a gear, not an ellipsis. */
function repairSettingsGlyph(source) {
  const range = accountMenuRange(source)
  if (!range) return { source, changed: false }
  const menu = source.slice(range.menuStart, range.menuEnd)
  let nextMenu = menu
  if (nextMenu.includes(UNSIGNED_ELLIPSIS_PRETTY)) {
    nextMenu = nextMenu.replace(UNSIGNED_ELLIPSIS_PRETTY, UNSIGNED_GEAR_PRETTY)
  } else if (nextMenu.includes(UNSIGNED_ELLIPSIS_COMPACT)) {
    nextMenu = nextMenu.replace(UNSIGNED_ELLIPSIS_COMPACT, UNSIGNED_GEAR_COMPACT)
  } else {
    return { source, changed: false }
  }
  return {
    source: source.slice(0, range.menuStart) + nextMenu + source.slice(range.menuEnd),
    changed: true,
  }
}

/** Apply Praxis AccountMenu behavior to a compiled settings-account client bundle. */
export function patchAccountMenuSource(source) {
  if (source.includes(MARKER)) {
    const repaired = repairSettingsGlyph(source)
    return { source: repaired.source, changed: repaired.changed, already: !repaired.changed, steps: repaired.changed ? ['ellipsis→gear'] : undefined }
  }

  let next = source
  const steps = []
  const compact = next.includes('signedIn?label:t(`more`)') || next.includes('onClick:()=>{setOpen(value=>!value)}')

  // 0.1.x used signedOut; 0.2.1 uses "more"; 0.2.2+ compact uses `more`.
  const labelPatterns = [
    ['signedIn ? label : t("signedOut")', 'signedIn ? label : t("settings")', 'signedOut'],
    ['signedIn ? label : t("more")', 'signedIn ? label : t("settings")', 'more'],
    ['signedIn?label:t(`signedOut`)', 'signedIn?label:t(`settings`)', 'signedOut'],
    ['signedIn?label:t(`more`)', 'signedIn?label:t(`settings`)', 'more'],
  ]
  const labelHit = labelPatterns.find(([pattern]) => next.includes(pattern))
  if (!labelHit) throw new Error('AccountMenu patch: unsigned label pattern missing (signedOut|more)')
  next = next.replaceAll(labelHit[0], labelHit[1])
  steps.push(`label(${labelHit[2]})→settings`)

  const range = accountMenuRange(next)
  if (!range) throw new Error('AccountMenu patch: function AccountMenu missing')
  const before = next.slice(0, range.menuStart)
  let menu = next.slice(range.menuStart, range.menuEnd)
  const after = next.slice(range.menuEnd)

  const togglePretty = /onClick:\s*\(\)\s*=>\s*\{\s*setOpen\(\(value\)\s*=>\s*!value\);\s*\}/
  const toggleCompact = /onClick:\(\)=>\{setOpen\(value=>!value\)\}/
  if (togglePretty.test(menu)) {
    menu = menu.replace(
      togglePretty,
      'onClick: () => { if (signedIn) setOpen((value) => !value); else openSettings(); }',
    )
  } else if (toggleCompact.test(menu)) {
    menu = menu.replace(
      toggleCompact,
      'onClick:()=>{if(signedIn)setOpen(value=>!value);else openSettings()}',
    )
  } else {
    throw new Error('AccountMenu patch: toggle onClick pattern missing in AccountMenu')
  }
  steps.push('click→openSettings')
  next = before + menu + after

  const contactPretty = /\{\s*id:\s*"contact",\s*label:\s*t\("contactUs"\),[\s\S]*?\},/
  const contactCompact = /\{id:`contact`,label:t\(`contactUs`\),icon:\(0,react_jsx_runtime\.jsx\)\([^}]+\}\)\},/
  if (contactPretty.test(next)) {
    next = next.replace(contactPretty, '')
  } else if (contactCompact.test(next)) {
    next = next.replace(contactCompact, '')
  } else {
    throw new Error('AccountMenu patch: contact menu item missing')
  }
  steps.push('drop-contact')

  const signInPretty = /\.\.\.signedIn\s*\?\s*\[\{[\s\S]*?id:\s*"signout"[\s\S]*?\}\]\s*:\s*\[\{[\s\S]*?id:\s*"signin"[\s\S]*?\}\]/
  const signInCompact = /\.\.\.signedIn\?\[\{id:`signout`[\s\S]*?\}\]:\[\{id:`signin`[\s\S]*?\}\]/
  if (signInPretty.test(next)) {
    next = next.replace(signInPretty, (match) => match.replace(/:\s*\[\{[\s\S]*?id:\s*"signin"[\s\S]*?\}\]/, ': []'))
  } else if (signInCompact.test(next)) {
    next = next.replace(signInCompact, (match) => match.replace(/:\[\{id:`signin`[\s\S]*?\}\]/, ':[]'))
  } else {
    throw new Error('AccountMenu patch: signin/signout branch missing')
  }
  steps.push('drop-signin')

  next = next.replace(/\s*else if \(id === "contact"\) \{\s*setOpen\(false\);\s*contactUs\(\);\s*\}/g, '')
  next = next.replace(/else if\(id===`contact`\)\{setOpen\(false\);contactUs\(\)\}/g, '')
  next = next.replace(/\s*else if \(id === "signin"\) beginSignIn\(\);/g, '')
  next = next.replace(/else if\(id===`signin`\)beginSignIn\(\);/g, '')
  next = next.replace(/,\s*contactUs(?=\s*,)/, '')
  next = next.replace(/,contactUs(?=,)/, '')
  next = next.replace(/const beginSignIn = \(\) => \{[\s\S]*?\};\n/, '')
  next = next.replace(/const beginSignIn=\(\)=>\{[^}]*\};/, '')

  const assertRange = accountMenuRange(next)
  const menuBody = assertRange ? next.slice(assertRange.menuStart, assertRange.menuEnd) : next
  if (menuBody.includes('id: "contact"') || menuBody.includes('id:`contact`') || menuBody.includes('id: "signin"') || menuBody.includes('id:`signin`')) {
    throw new Error('AccountMenu patch: residual contact/signin markers remain in AccountMenu')
  }
  if (
    menuBody.includes('t("signedOut")') ||
    menuBody.includes('t(`signedOut`)') ||
    /signedIn \? label : t\("more"\)/.test(menuBody) ||
    menuBody.includes('signedIn?label:t(`more`)')
  ) {
    throw new Error('AccountMenu patch: residual unsigned label remain in AccountMenu')
  }
  if (!menuBody.includes('else openSettings()') && !menuBody.includes('else openSettings();') && !menuBody.includes('else openSettings()}')) {
    throw new Error('AccountMenu patch: openSettings click missing after transform')
  }

  next = MARKER + '\n' + next
  const repaired = repairSettingsGlyph(next)
  if (repaired.changed) steps.push('ellipsis→gear')
  return { source: repaired.source, changed: true, already: false, steps, compact }
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
  const samplePretty = `
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
  const once = patchAccountMenuSource(samplePretty)
  if (!once.changed) throw new Error('self-test: expected change')
  const twice = patchAccountMenuSource(once.source)
  if (!twice.already) throw new Error('self-test: expected idempotent skip')
  if (once.source.includes('id: "contact"')) throw new Error('self-test: contact row still present')
  if (!once.source.includes('signedIn ? label : t("settings")')) throw new Error('self-test: settings label missing')
  if (!once.source.includes('else openSettings()')) throw new Error('self-test: openSettings click missing')

  const sampleCompact = `function AccountMenu({wide,openSettings,contactUs,showLogin,start,cancel,t}){const beginSignIn=()=>{setOpen(false);start().catch(()=>void 0)};return(0,react_jsx_runtime.jsxs)(\`div\`,{children:[(0,react_jsx_runtime.jsx)(Menu,{anchor:(0,react_jsx_runtime.jsxs)(\`button\`,{"aria-haspopup":\`menu\`,"aria-expanded":open,onClick:()=>{setOpen(value=>!value)},children:[signedIn?(0,react_jsx_runtime.jsx)(\`span\`,{}):(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconEllipsisOutlineMedium,{size:14}),wide&&(0,react_jsx_runtime.jsx)(\`span\`,{children:signedIn?label:t(\`more\`)})]}),items:[{id:\`settings\`,label:t(\`settings\`)},{id:\`contact\`,label:t(\`contactUs\`),icon:(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconPaperPlaneOutlineMedium,{size:16})},...signedIn?[{id:\`signout\`,label:t(\`signOut\`),disabled:busy}]:[{id:\`signin\`,label:t(\`signIn\`),icon:(0,react_jsx_runtime.jsx)(_deepseek_ai_dsh_client_ui_primitives.IconUserOutlineMedium,{size:16})}],onSelect:id=>{if(id===\`settings\`){setOpen(false);openSettings()}else if(id===\`contact\`){setOpen(false);contactUs()}else if(id===\`signin\`)beginSignIn();else requestSignOut()}})]})}function createPlatformPages(){return null}`
  const compactOnce = patchAccountMenuSource(sampleCompact)
  if (!compactOnce.changed) throw new Error('self-test compact: expected change')
  if (compactOnce.source.includes('id:`contact`') || compactOnce.source.includes('id:`signin`')) {
    throw new Error('self-test compact: contact/signin remain')
  }
  if (!compactOnce.source.includes('signedIn?label:t(`settings`)')) throw new Error('self-test compact: settings label missing')
  if (!compactOnce.source.includes('else openSettings()}')) throw new Error('self-test compact: openSettings click missing')
  if (!compactOnce.source.includes(UNSIGNED_GEAR_COMPACT)) throw new Error('self-test compact: gear glyph missing')
  const compactTwice = patchAccountMenuSource(compactOnce.source)
  if (!compactTwice.already) throw new Error('self-test compact: expected idempotent skip')

  console.log('patch-account-menu self-test ok:', once.steps.join(', '), '| compact:', compactOnce.steps.join(', '))
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
