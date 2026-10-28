#!/usr/bin/env node

import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { CATALOG_PACKAGES, ENTERPRISE_PACKAGES, PRODUCT_PACKAGES } from './workdsh-package-boundary.mjs'

const runtime = resolve(process.argv[2] ?? fileURLToPath(new URL('../build/workdsh-runtime', import.meta.url)))
const source = join(runtime, 'profiles', 'kaiwu')
const profile = resolve(process.argv[3] ?? source)
const installedInProfile = profile === source
const config = join(profile, '.workdsh-plugin-inventory-probe.yml')
const expected = PRODUCT_PACKAGES
const anchor = join(source, 'profile-installation.json')
if (!existsSync(anchor)) throw new Error(`Missing bundled DSH installation: ${anchor}`)
const installation = JSON.parse(readFileSync(anchor, 'utf8'))
// Profile optionals are projected into installation peers. 企业连接 may appear
// there as shippable media; identity/collaboration must stay out entirely, and
// no enterprise package may be a required dependency of the base installer.
for (const name of ENTERPRISE_PACKAGES) {
  if (installation.dependencies?.[name]) {
    throw new Error('Base installer must not activate enterprise plugins as required deps: ' + name)
  }
  if (name !== 'workdsh-enterprise-connection' && installation.peerDependencies?.[name]) {
    throw new Error('Base installer must not activate enterprise plugins as required deps: ' + name)
  }
}

process.env.DSH_HOME = runtime
const packages = join(source, 'node_modules', '@deepseek-ai')
const { boot } = await import(pathToFileURL(join(packages, 'dsh-app-boot', 'lib', 'index.js')).href)
const { default: PluginManager } = await import(pathToFileURL(join(packages, 'dsh-plugin-manager', 'lib', 'index.js')).href)

let ctx
try {
  writeFileSync(config, JSON.stringify([{ id: 'manager', name: 'cordis:manager' }]))
  ctx = await boot('dsh', config, [], root => {
    root.provide('profileContext', {
      name: 'kaiwu', dir: profile, home: runtime, cwd: runtime,
      patchPath: join(profile, 'cordis.patch.yml'), installAnchor: anchor,
      startedBundles: [], overlays: [], telemetryDisabledEnv: undefined,
    })
    root.loader.builtins.manager = PluginManager
  })
  const allBundles = await ctx.pluginManager.listBundles()
  const bundles = allBundles.filter(row => row.name.startsWith('workdsh-') && !ENTERPRISE_PACKAGES.includes(row.name))
  const names = bundles.map(row => row.name).sort()
  if (JSON.stringify(names) !== JSON.stringify(expected)) {
    throw new Error(`Plugin manager exposes ${names.join(', ') || '(none)'}; expected ${expected.join(', ')}`)
  }
  for (const bundle of bundles) {
    if (!bundle.enabled || bundle.installed !== installedInProfile || bundle.removable || bundle.error) {
      throw new Error(`kaiwu product bundle is inactive or invalid: ${bundle.name}: ${JSON.stringify(bundle)}`)
    }
  }
  const connection = allBundles.find(row => row.name === 'workdsh-enterprise-connection')
  if (!connection?.enabled || connection.error) {
    throw new Error('企业连接 must be enabled in the personal base Profile')
  }
  for (const name of ENTERPRISE_PACKAGES) {
    if (name === 'workdsh-enterprise-connection') continue
    const bundle = allBundles.find(row => row.name === name)
    if (bundle?.enabled) throw new Error('Enterprise bundle must stay disabled in the personal base Profile: ' + name)
  }
  for (const name of Object.keys(CATALOG_PACKAGES)) {
    const bundle = allBundles.find(row => row.name === name)
    if (!bundle?.enabled || bundle.installed !== installedInProfile || bundle.error) {
      throw new Error(`Community catalog integration is inactive or invalid: ${name}: ${JSON.stringify(bundle)}`)
    }
  }
  console.log(`Verified plugin manager exposes exactly ${expected.length} ${installedInProfile ? 'installed' : 'installation-provided'} kaiwu product bundles: ${names.join(', ')}`)
} finally {
  try {
    await ctx?.fiber.dispose()
  } finally {
    rmSync(config, { force: true })
  }
}
