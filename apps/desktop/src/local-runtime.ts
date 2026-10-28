/** Writable Profile/configuration over the official installation anchor. No custom Loader. */
import { createHash, randomUUID } from 'node:crypto'
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { load, dump } from 'js-yaml'
import { syncBundledCompatibility } from './runtime-compatibility.ts'
import { cachedPackageManager } from './plugin-archive-cache.ts'
import { enterpriseNamespace } from './connection-mode.ts'
import type { EnterpriseMember, Authority } from './enterprise-auth.ts'

type ProfilePackage = { dependencies?: Record<string, string>, optionalDependencies?: Record<string, string>, dsh?: { profile?: { bundles?: string[] } }, [key: string]: unknown }
const BASE_STATE = '.workdsh-desktop-base.json'
const json = (file: string): ProfilePackage => JSON.parse(readFileSync(file, 'utf8')) as ProfilePackage
const writeJson = (file: string, value: unknown): void => writeFileSync(file, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 })
function memberDefaults(release: ProfilePackage): ProfilePackage {
  const dependencies: Record<string, string> = {}
  // Carry 企业连接 into new personal Homes when the bundled Profile ships it.
  const connection = release.optionalDependencies?.['workdsh-enterprise-connection']
    ?? release.dependencies?.['workdsh-enterprise-connection']
  if (typeof connection === 'string') dependencies['workdsh-enterprise-connection'] = connection
  const dsh = release.dsh ? structuredClone(release.dsh) : undefined
  // Keep personal bundles free of enterprise activation; connection package is install-only until login.
  if (dsh?.profile?.bundles) {
    dsh.profile.bundles = dsh.profile.bundles.filter(name => !name.startsWith('workdsh-provider-identity-enterprise')
      && !name.startsWith('workdsh-plugin-enterprise-collaboration')
      && name !== 'workdsh-enterprise-connection')
  }
  return { name: 'workdsh-member-profile', private: true, type: 'module', packageManager: release.packageManager,
    dependencies, ...(dsh ? { dsh } : {}) }
}

/** IM 机器人 stays under Settings; hide the duplicate sidebar entry by default. */
function hideImSidebar(home: string): void {
  const sidebar = join(home, 'integrations', 'dsh-im')
  mkdirSync(sidebar, { recursive: true, mode: 0o700 })
  writeJson(join(sidebar, 'sidebar-settings.json'), { version: 1, mode: 'hide' })
}

/** Fresh personal Profiles hide better-sidebar Git / Diff tabs; settings can re-enable. */
const PERSONAL_SIDEBAR_DEFAULTS = `- id: better-sidebar
  config:
    tabsEnabled:
      git: false
      diff: false
`
function baseDigest(source: string, base: ProfilePackage, version: string): string {
  const marker = join(source, '.workdsh-desktop-release.json')
  const workspace = join(source, 'pnpm-workspace.yaml')
  return createHash('sha256').update('installation-owned-defaults-v2').update(JSON.stringify(base)).update(version).update(existsSync(marker) ? readFileSync(marker) : '')
    .update(existsSync(workspace) ? readFileSync(workspace) : '').digest('hex')
}

function updatePackagePolicy(source: string, target: string): boolean {
  const policy = join(source, 'pnpm-workspace.yaml'), current = join(target, 'pnpm-workspace.yaml')
  if (!existsSync(policy)) return false
  const parse = (path: string): Record<string, unknown> => {
    const value = load(readFileSync(path, 'utf8'))
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Profile 包管理配置必须是 YAML 对象')
    return value as Record<string, unknown>
  }
  if (!existsSync(current)) {
    const defaults = parse(policy)
    // Like the official external Profile initializer, use installation-owned service peers.
    defaults.autoInstallPeers = false
    writeFileSync(current, dump(defaults), { mode: 0o600 })
    return true
  }
  const owned = parse(policy), user = parse(current)
  if (JSON.stringify(user.overrides) === JSON.stringify(owned.overrides)) return false
  if ((user.overrides !== undefined && (!user.overrides || typeof user.overrides !== 'object' || Array.isArray(user.overrides)))
    || !owned.overrides || typeof owned.overrides !== 'object' || Array.isArray(owned.overrides)) throw new Error('Profile 包版本约束无效')
  // Official runtime/Cordis versions are product-owned. Other install preferences and overrides are user-owned.
  const overrides = { ...user.overrides as Record<string, unknown>, ...owned.overrides as Record<string, unknown> }
  if (JSON.stringify(user.overrides) === JSON.stringify(overrides)) return false
  user.overrides = overrides
  writeFileSync(current, dump(user), { mode: 0o600 })
  return true
}

export function materializeRuntimeProfile(source: string, home: string): { profile: string, changed: boolean } {
  const target = join(home, 'profiles', 'kaiwu')
  const release = json(join(source, 'package.json'))
  // Defaults are already installed in the immutable runtime. The member project owns only explicit additions.
  const base = memberDefaults(release)
  const version = json(join(source, 'node_modules', '@deepseek-ai', 'dsh', 'package.json')).version
  if (typeof version !== 'string') throw new Error('Bundled DSH version is missing')
  const state = join(target, BASE_STATE)
  const manifest = join(target, 'package.json')
  const modules = join(target, 'node_modules')
  mkdirSync(target, { recursive: true, mode: 0o700 })
  // A previous shared symlink is not safe for plugin writes. Refuse to mutate it.
  if (existsSync(modules) && lstatSync(modules).isSymbolicLink()) throw new Error('此 Profile 的依赖仍链接到安装包，请选择独立的可写空间后再启动')
  const digest = baseDigest(source, release, version)
  const previous = existsSync(state) ? JSON.parse(readFileSync(state, 'utf8')) as { digest: string, base: ProfilePackage, pendingInstallation?: boolean } : undefined
  let changed = previous?.pendingInstallation === true
  if (!existsSync(manifest)) {
    writeJson(manifest, base)
    writeFileSync(join(target, 'cordis.patch.yml'), PERSONAL_SIDEBAR_DEFAULTS, { mode: 0o600 })
    // Bundled optional media (e.g. 企业连接) is carried into member dependencies and must install.
    changed = Object.keys(base.dependencies ?? {}).length > 0 || Object.keys(base.optionalDependencies ?? {}).length > 0
  } else if (previous?.digest !== digest) {
    if (!previous) throw new Error('已有 Profile 缺少 Desktop 版本记录；请在官方插件管理中核对后使用独立空间')
    const current = json(manifest)
    // Only the unchanged recorded default remains product-owned. A user may
    // pin another manager/version or remove the declaration altogether.
    if (current.packageManager === previous.base.packageManager) {
      if (base.packageManager === undefined) delete current.packageManager
      else current.packageManager = base.packageManager
    }
    for (const section of ['dependencies', 'optionalDependencies'] as const) {
      const owned = previous.base[section] ?? {}
      const next = base[section] ?? {}
      current[section] ??= {}
      for (const [name, value] of Object.entries(owned)) {
        if (current[section]![name] !== value) continue // Explicit user removal/change remains owned by the user.
        if (next[name] === undefined) delete current[section]![name]
        else current[section]![name] = next[name]!
      }
      for (const [name, value] of Object.entries(next)) {
        if (owned[name] === undefined && current[section]![name] === undefined) current[section]![name] = value
      }
    }
    const selected = current.dsh?.profile?.bundles ?? []
    const oldBundles = previous.base.dsh?.profile?.bundles ?? []
    const nextBundles = base.dsh?.profile?.bundles ?? []
    current.dsh ??= {}; current.dsh.profile ??= {}
    current.dsh.profile.bundles = selected.filter(name => !oldBundles.includes(name) || nextBundles.includes(name))
    for (const name of nextBundles) if (!oldBundles.includes(name) && !current.dsh.profile.bundles.includes(name)) current.dsh.profile.bundles.push(name)
    if (JSON.stringify(json(manifest)) !== JSON.stringify(current)) {
      writeJson(manifest, current)
      // Changed owned dependency graph requires install; new Homes may not have node_modules yet.
      const depsChanged = ['dependencies', 'optionalDependencies'].some(section => JSON.stringify(previous.base[section]) !== JSON.stringify(base[section]))
      const hasMemberDeps = Object.keys(base.dependencies ?? {}).length > 0 || Object.keys(base.optionalDependencies ?? {}).length > 0
      changed ||= depsChanged && (existsSync(modules) || hasMemberDeps)
    }
  }
  const policyChanged = updatePackagePolicy(source, target)
  if (policyChanged && existsSync(modules)) changed = true
  const cache = join(home, 'package-cache')
  const sourceCache = join(source, '..', '..', 'package-cache')
  if (existsSync(sourceCache)) cpSync(sourceCache, cache, { recursive: true, force: false, errorOnExist: false })
  syncBundledCompatibility(source, target, digest)
  // Settings already lists IM机器人; do not also pin it in the personal sidebar.
  hideImSidebar(home)
  // Caller installs changed dependencies with the pinned official package manager before marking success.
  if (changed) writeJson(state, { digest: previous?.digest ?? digest, base: previous?.base ?? base, pendingInstallation: true })
  else writeJson(state, { digest, base })
  return { profile: target, changed }
}

export function markProfileUpdated(source: string, profile: string): void {
  const release = json(join(source, 'package.json'))
  const base = memberDefaults(release)
  const version = json(join(source, 'node_modules', '@deepseek-ai', 'dsh', 'package.json')).version as string
  const digest = baseDigest(source, release, version)
  writeJson(join(profile, BASE_STATE), { digest, base })
}

export function enterpriseSpace(userData: string, backend: string, actor: EnterpriseMember): { root: string, home: string, deviceId: string } {
  const root = join(userData, 'enterprise', enterpriseNamespace(backend, actor.organizationId, actor.id))
  mkdirSync(root, { recursive: true, mode: 0o700 })
  const deviceFile = join(root, 'device.json')
  if (!existsSync(deviceFile)) writeJson(deviceFile, { deviceId: randomUUID() })
  const parsed: unknown = JSON.parse(readFileSync(deviceFile, 'utf8'))
  const deviceId = (parsed as { deviceId?: unknown }).deviceId
  if (typeof deviceId !== 'string' || !/^[0-9a-f-]{36}$/u.test(deviceId)) throw new Error('企业本机设备记录无效')
  for (const name of ['home', 'dsh', 'agents', 'workspace', 'tmp', 'appdata', 'localappdata']) mkdirSync(join(root, name), { recursive: true, mode: 0o700 })
  const home = join(root, 'dsh')
  // Settings already contains IM机器人. Enterprise login does not add a second sidebar entry.
  hideImSidebar(home)
  return { root, home, deviceId }
}

export function enterpriseEnvironment(root: string, executable: string, parent: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const result: NodeJS.ProcessEnv = {}
  for (const key of ['SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'LANG', 'LC_ALL', 'TZ', 'DISPLAY', 'WAYLAND_DISPLAY']) if (parent[key]) result[key] = parent[key]
  result.PATH = `${dirname(executable)}${process.platform === 'win32' ? ';' : ':'}${parent.PATH ?? ''}`
  result.HOME = join(root, 'home'); result.USERPROFILE = result.HOME
  result.DSH_HOME = join(root, 'dsh'); result.DSH_AGENTS_HOME = join(root, 'agents')
  result.TMPDIR = join(root, 'tmp'); result.TMP = result.TMPDIR; result.TEMP = result.TMPDIR
  result.APPDATA = join(root, 'appdata'); result.LOCALAPPDATA = join(root, 'localappdata')
  return result
}

export function officialLauncher(source: string, home: string, executable: string, packageManager: string = join(dirname(executable), '..', '..', 'pnpm', 'bin', 'pnpm.cjs')): string {
  const cli = join(source, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
  if (!existsSync(cli) || !existsSync(packageManager)) throw new Error('安装包缺少官方 DSH 或锁定的插件安装工具')
  const pnpm = cachedPackageManager(home, packageManager)
  const launcher = join(home, '.workdsh-launch.mjs')
  writeFileSync(launcher, `import { runCli } from ${JSON.stringify(pathToFileURL(cli).href)};\nawait runCli({ manageDesktopProfile: true, packageManager: { command: ${JSON.stringify(executable)}, args: [${JSON.stringify(pnpm)}] } });\n`, { mode: 0o600 })
  return launcher
}

/** The official application-owned Profile API supplies the full installation dependency graph. */
export function officialHostLauncher(source: string, home: string, executable: string, packageManager: string, patches: string[]): string {
  const cli = join(source, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
  const boot = join(source, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'profile-boot.js')
  const appBoot = join(source, 'node_modules', '@deepseek-ai', 'dsh-app-boot', 'lib', 'index.js')
  if (!existsSync(cli) || !existsSync(boot) || !existsSync(appBoot) || !existsSync(packageManager)) throw new Error('安装包缺少官方 Profile 启动接口')
  const anchor = join(source, 'profile-installation.json'), profile = join(home, 'profiles', 'kaiwu')
  if (!existsSync(anchor)) throw new Error('安装包缺少完整官方与 开物Praxis 安装清单')
  // The market re-invokes whatever launched this process when argv[1] ends in
  // bin.js. A packaged app has no `dsh` on PATH, so the host entry has to be
  // that script and forward `plugin` to the official CLI.
  const launcher = join(home, '.workdsh-host', 'bin.js')
  mkdirSync(dirname(launcher), { recursive: true })
  writeJson(join(home, '.workdsh-host', 'package.json'), { type: 'module' })
  packageManager = cachedPackageManager(home, packageManager)
  const packageManagerLiteral = `{ command: ${JSON.stringify(executable)}, args: [${JSON.stringify(packageManager)}] }`
  writeFileSync(launcher, `import { runCli } from ${JSON.stringify(pathToFileURL(cli).href)};\nimport { runProfile } from ${JSON.stringify(pathToFileURL(boot).href)};\nimport { loadProfileDirectory, loadLayeredEnv, reportSkippedBundles } from ${JSON.stringify(pathToFileURL(appBoot).href)};\nconst installAnchor = ${JSON.stringify(anchor)};\nconst profile = loadProfileDirectory('dsh', ${JSON.stringify(profile)}, installAnchor);\nconst packageManager = ${packageManagerLiteral};\nif (process.argv[2] === 'plugin') await runCli({ manageDesktopProfile: true, packageManager });\nelse { reportSkippedBundles('dsh', profile);\nawait runProfile({ environment: loadLayeredEnv('dsh'), profile: 'kaiwu', resolvedProfile: { profile, installAnchor }, patchFiles: ${JSON.stringify(patches)}, args: process.argv.slice(2), packageManager }); }\n`, { mode: 0o600 })
  return launcher
}

export function desktopEnterprisePatch(home: string, authority: Authority, actor: EnterpriseMember, backendUrl: string, deviceId: string, collaboration = true): { authFile: string, patch: string } {
  // The root enterprise bundle contributes the shared account client; only ./desktop supplies identity.
  const authFile = join(home, 'enterprise-auth.json')
  writeJson(authFile, { authorityUrl: authority.url, authorityKey: authority.key, backendUrl, principalId: actor.id, organizationId: actor.organizationId, deviceId })
  const patch = join(home, '.enterprise-desktop.patch.yml')
  writeFileSync(patch, `- id: workdsh-identity-local\n  disabled: true\n- insert:\n    - id: workdsh-enterprise-account-client\n      name: workdsh-provider-identity-enterprise\n    - id: workdsh-desktop-identity\n      name: workdsh-provider-identity-enterprise/desktop\n      config:\n        authFile: ${JSON.stringify(authFile)}\n        principalId: ${JSON.stringify(actor.id)}\n        organizationId: ${JSON.stringify(actor.organizationId)}\n        deviceId: ${JSON.stringify(deviceId)}\n${collaboration ? `- insert:\n    - id: workdsh-desktop-collaboration\n      name: workdsh-plugin-enterprise-collaboration\n      config:\n        desktop: true\n` : ''}- id: workdsh-session-access\n  config:\n    autoBindFixedMemberSessions: true\n- id: workdsh-tool-access\n  config:\n    autoBindPersonalSessions: false\n    autoBindFixedMemberSessions: true\n- id: workspace-controller\n  config:\n    documentsDirectory: ${JSON.stringify(join(home, '..', 'workspace'))}\n`, { mode: 0o600 })
  return { authFile, patch }
}
