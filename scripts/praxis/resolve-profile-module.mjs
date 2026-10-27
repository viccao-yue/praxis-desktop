/** Resolve a file inside an installed Profile package (pnpm layout, incl. Windows). */
import { createRequire } from 'node:module'
import { existsSync, globSync, readdirSync, realpathSync } from 'node:fs'
import { join, resolve } from 'node:path'

/**
 * @param {string} root Profile directory (…/profiles/kaiwu)
 * @param {string} packageName e.g. @deepseek-ai/dsh-client-ui-settings-account
 * @param {string} subpath e.g. lib/client.js or client (package exports key)
 */
export function resolveProfilePackageFile(root, packageName, subpath) {
  const profileRoot = resolve(root)
  const direct = join(profileRoot, 'node_modules', ...packageName.split('/'), ...subpath.split('/'))
  if (existsSync(direct)) return realpathSync(direct)

  const anchors = [
    join(profileRoot, 'package.json'),
    join(profileRoot, 'node_modules/@deepseek-ai/dsh-web-app/package.json'),
    join(profileRoot, 'node_modules/@deepseek-ai/dsh-deepseek-account/package.json'),
    join(profileRoot, 'node_modules/@deepseek-ai/dsh-client-ui-settings/package.json'),
    join(profileRoot, 'node_modules/@deepseek-ai/dsh-client-ui-plugin-manager/package.json'),
    join(profileRoot, 'node_modules/@deepseek-ai/dsh/package.json'),
  ]
  // Official client packages expose `./client` → lib/client.js; bare lib/ paths are blocked by exports.
  const exportKey = subpath === 'lib/client.js' || subpath === 'client.js'
    ? 'client'
    : subpath.replace(/^lib\//, '').replace(/\.js$/, '')
  const specifiers = [
    `${packageName}/${exportKey}`,
    `${packageName}/client`,
    `${packageName}/${subpath}`,
    packageName,
  ]
  for (const anchor of anchors) {
    if (!existsSync(anchor)) continue
    let require
    try {
      require = createRequire(realpathSync(anchor))
    } catch {
      try {
        require = createRequire(anchor)
      } catch {
        continue
      }
    }
    for (const specifier of specifiers) {
      try {
        const resolved = require.resolve(specifier)
        if (existsSync(resolved)) return realpathSync(resolved)
      } catch {
        /* try next */
      }
    }
  }

  const pnpm = join(profileRoot, 'node_modules/.pnpm')
  const needle = packageName.replaceAll('/', '+')
  const leaf = join('node_modules', ...packageName.split('/'), ...subpath.split('/'))
  if (existsSync(pnpm)) {
    for (const entry of readdirSync(pnpm)) {
      if (!entry.includes(needle)) continue
      const path = join(pnpm, entry, leaf)
      if (existsSync(path)) return realpathSync(path)
    }
  }

  // Nested under a consumer virtual-store folder (hashed peer suffix / Windows layout).
  const matches = globSync(`**/node_modules/${packageName}/${subpath}`, {
    cwd: profileRoot,
    absolute: true,
    nodir: true,
  })
  if (matches.length) return realpathSync(matches[0])

  throw new Error(`${packageName} ${subpath} not found under ${profileRoot}`)
}
