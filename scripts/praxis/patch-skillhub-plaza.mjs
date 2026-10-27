#!/usr/bin/env node
/**
 * Hide SkillHub 插件广场's 技能 tab. Skills already live under 技能 · 连接器.
 * The plaza keeps the 插件 catalog.
 *
 * Usage:
 *   node scripts/praxis/patch-skillhub-plaza.mjs <profile-or-package-root>
 *   node scripts/praxis/patch-skillhub-plaza.mjs --self-test
 */
import { existsSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const MARKER = '/* praxis-skillhub-plaza-patched */'
const PANEL_MARKER = '/* praxis-skillhub-plaza-panel */'

const SKILLS_TAB = `h("button", {
                type: "button",
                role: "tab",
                className: "sh-plaza-tab" + (tab === "skills" ? " on" : ""),
                "aria-selected": tab === "skills",
                onClick: () => setTab("skills"),
              }, tr("plaza.skills")),`

const SKILLS_BODY = 'tab === "skills" ? h(SkillPlaza) : h(Marketplace, { t: tr })'
const PLUGINS_BODY = 'h(Marketplace, { t: tr })'

const FOOTER = `slots.inject("sidebar.footer.action", () => registerSlot(
        slots,
        { name: "sidebar.footer.action", id: "skillhub-plaza", order: 8, label: () => lookup("plaza.title"), locale: "skillhub" },
        function PlazaEntry(actionProps) {
          return h(PlazaAction, { ...actionProps, sessions });
        },
      ));`

const PANEL = `slots.inject("sidebar.panellist", () => registerSlot(
        slots,
        { name: "sidebar.panellist", id: "skillhub-plaza", order: 44, label: () => lookup("plaza.title"), locale: "skillhub" },
        function PlazaNavIcon({ size }) {
          return h(PlazaIcon, { size });
        },
      ));
      slots.inject("main", () => registerSlot(
        slots,
        { name: "main", key: "skillhub-plaza", locale: "skillhub" },
        PlazaPanel,
      ));`

const PLAZA_PANEL_FN = `    function PlazaPanel() {
      useEffect(() => ensureCss(), []);
      const tr = lookup;
      return h("section", { className: "sh-plaza-panel", "aria-label": tr("plaza.title") },
        h("style", null, ".sh-plaza-panel{box-sizing:border-box;height:100%;min-height:0;overflow:auto;padding:28px clamp(24px,4vw,48px) 48px;background:var(--dsw-alias-bg-base,#fff);color:var(--dsw-alias-label-primary,#17191c);font:14px/22px inherit}.sh-plaza-panel *{box-sizing:border-box}.sh-plaza-panel-head{margin:0 0 20px}.sh-plaza-panel-head h1{margin:0;font-size:20px;font-weight:500;line-height:28px}[data-platform=darwin] .sh-plaza-panel{padding-top:calc(28px + var(--dsh-frame-top-clearance,0px))}.sh-plaza-panel .sh-mkt{max-width:none;width:100%}.sh-plaza-panel .sh-mkt-grid{grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}@media (max-width:1400px){.sh-plaza-panel .sh-mkt-grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media (max-width:980px){.sh-plaza-panel .sh-mkt-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media (max-width:640px){.sh-plaza-panel .sh-mkt-grid{grid-template-columns:1fr}}"),
        h("header", { className: "sh-plaza-panel-head" }, h("h1", null, tr("plaza.title"))),
        h(Marketplace, { t: tr }),
      );
    }
`

/** Drop the skills tab, then mount the plugin catalog as a normal sidebar page. */
export function patchSkillhubPlazaSource(source) {
  let next = source
  let changed = false
  if (!next.includes(MARKER)) {
    if (!next.includes(SKILLS_TAB)) throw new Error('SkillHub plaza patch: skills tab missing')
    if (!next.includes(SKILLS_BODY)) throw new Error('SkillHub plaza patch: skills body missing')
    next = MARKER + '\n' + next.replace(SKILLS_TAB, '').replace(SKILLS_BODY, PLUGINS_BODY)
    changed = true
  }
  if (!next.includes(PANEL_MARKER)) {
    if (!next.includes(FOOTER)) throw new Error('SkillHub plaza patch: footer entry missing')
    if (!next.includes('function PlazaIcon() {')) throw new Error('SkillHub plaza patch: PlazaIcon missing')
    next = next.replace(FOOTER, PANEL)
    next = next.replace('function PlazaIcon() {', 'function PlazaIcon({ size } = {}) {')
    next = next.replace('    const inject = ["slots", "sessions"];', `${PLAZA_PANEL_FN}    const inject = ["slots", "sessions"];`)
    next = PANEL_MARKER + '\n' + next
    changed = true
  }
  const icons = repairPlazaIcons(next)
  next = icons.source
  changed = changed || icons.changed
  if (next.includes('sidebar.footer.action') || next.includes('tr("plaza.skills")') || next.includes(SKILLS_BODY)) {
    throw new Error('SkillHub plaza patch: overlay or skills tab still present')
  }
  if (!next.includes('name: "sidebar.panellist"') || !next.includes('function PlazaPanel()') || !next.includes(PLUGINS_BODY)) {
    throw new Error('SkillHub plaza patch: sidebar page missing')
  }
  if (next.includes('function SearchIcon() {\n      return h("svg", { width: size')) {
    throw new Error('SkillHub plaza patch: search icon still depends on size')
  }
  if (!next.includes('function PlazaIcon({ size } = {}) {\n      return h("svg", { width: size || 16, height: size || 16,')) {
    throw new Error('SkillHub plaza patch: plaza icon has no size')
  }
  return { source: next, changed, already: !changed }
}

const BROKEN_SEARCH_ICON = `function SearchIcon() {
      return h("svg", { width: size || 16, height: size || 16, viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" },`
const SEARCH_ICON = `function SearchIcon() {
      return h("svg", { viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" },`
const UNSIZED_PLAZA_ICON = `function PlazaIcon({ size } = {}) {
      return h("svg", { viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" },`
const SIZED_PLAZA_ICON = `function PlazaIcon({ size } = {}) {
      return h("svg", { width: size || 16, height: size || 16, viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" },`

/** Keep the menu glyph sized, and do not leak that size into the search icon. */
function repairPlazaIcons(source) {
  let next = source
  let changed = false
  if (next.includes(BROKEN_SEARCH_ICON)) {
    next = next.replace(BROKEN_SEARCH_ICON, SEARCH_ICON)
    changed = true
  }
  if (next.includes(UNSIZED_PLAZA_ICON)) {
    next = next.replace(UNSIZED_PLAZA_ICON, SIZED_PLAZA_ICON)
    changed = true
  }
  return { source: next, changed }
}

function resolveClientBundle(root) {
  const candidates = [
    join(root, 'node_modules/@cocofhu/skillhub/lib/client.js'),
    join(root, 'lib/client.js'),
  ]
  for (const path of candidates) {
    if (existsSync(path)) return realpathSync(path)
  }
  const pnpm = join(root, 'node_modules/.pnpm')
  if (existsSync(pnpm)) {
    for (const entry of readdirSync(pnpm)) {
      if (!entry.includes('skillhub@') && !entry.includes('+skillhub@')) continue
      const path = join(pnpm, entry, 'node_modules/@cocofhu/skillhub/lib/client.js')
      if (existsSync(path)) return realpathSync(path)
    }
  }
  throw new Error('SkillHub plaza patch: @cocofhu/skillhub client.js not found under ' + root)
}

export function patchSkillhubPlazaAt(root) {
  const file = resolveClientBundle(root)
  const before = readFileSync(file, 'utf8')
  const result = patchSkillhubPlazaSource(before)
  if (result.changed) writeFileSync(file, result.source)
  return { file, ...result }
}

function selfTest() {
  const sample = `function SearchIcon() {
      return h("svg", { viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" },
        h("circle", { cx: "7", cy: "7", r: "5.25", stroke: "currentColor", strokeWidth: "1.5" }));
    }
    function PlazaIcon() {
      return h("svg", { viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" },
        h("rect", { x: "1.75", y: "1.75", width: "5.5", height: "5.5", rx: "1.2", stroke: "currentColor", strokeWidth: "1.4" }));
    }
    ${SKILLS_TAB}
    ${SKILLS_BODY}
    const inject = ["slots", "sessions"];
      ${FOOTER}`
  const once = patchSkillhubPlazaSource(sample)
  if (!once.changed) throw new Error('self-test: expected change')
  const twice = patchSkillhubPlazaSource(once.source)
  if (!twice.already) throw new Error('self-test: expected idempotent skip')
  if (once.source.includes('plaza.skills') || once.source.includes('sidebar.footer.action')) {
    throw new Error('self-test: old entry remains')
  }
  if (!once.source.includes('sidebar.panellist') || !once.source.includes('function PlazaPanel()')) {
    throw new Error('self-test: panel missing')
  }
  if (!once.source.includes('function SearchIcon() {\n      return h("svg", { viewBox:')) {
    throw new Error('self-test: search icon was resized')
  }
  if (!once.source.includes('width: size || 16')) throw new Error('self-test: plaza icon has no size')
  const installed = patchSkillhubPlazaSource(MARKER + '\n' + sample.replace(SKILLS_TAB, '').replace(SKILLS_BODY, PLUGINS_BODY))
  if (!installed.changed || installed.source.includes('sidebar.footer.action')) {
    throw new Error('self-test: installed file did not move to the sidebar')
  }
  console.log('patch-skillhub-plaza self-test ok')
}

const isMain = process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const args = process.argv.slice(2)
  if (args[0] === '--self-test') {
    selfTest()
  } else if (!args[0]) {
    console.error('Usage: node scripts/praxis/patch-skillhub-plaza.mjs <profile-or-package-root> | --self-test')
    process.exit(2)
  } else {
    const result = patchSkillhubPlazaAt(args[0])
    console.log(result.already ? 'SkillHub plaza already patched:' : 'SkillHub plaza patched:', result.file)
  }
}
