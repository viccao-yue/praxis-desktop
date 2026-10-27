/** Resolve a file inside an installed Profile package (pnpm layout, incl. Windows). */
import { createRequire } from 'node:module'
import { existsSync, readdirSync, realpathSync } from 'node:fs'
import { join } from 'node:path'

/**
 * @param {string} root Profile directory (…/profiles/kaiwu)
 * @param {string} packageName e.g. @deepseek-ai/dsh-client-ui-settings-account
 * @param {string} subpath e.g. lib/client.js or client (package exports key)
 */
export function resolveProfilePackageFile(root, packageName, subpath) {
  const direct = join(root, 'node_modules', ...packageName.split('/'), ...subpath.split('/'))
  if (existsSync(direct)) return realpathSync(direct)

  const anchors = [
    join(root, 'package.json'),
    join(root, 'node_modules/@deepseek-ai/dsh-web-app/package.json'),
    join(root, 'node_modules/@deepseek-ai/dsh-deepseek-account/package.json'),
    join(root, 'node_modules/@deepseek-ai/dsh-client-ui-settings/package.json'),
    join(root, 'node_modules/@deepseek-ai/dsh-client-ui-plugin-manager/package.json'),
    join(root, 'node_modules/@deepseek-ai/dsh/package.json'),
  ]
  const specifiers = subpath.includes('.')
    ? [`${packageName}/${subpath}`, packageName]
    : [`${packageName}/${subpath}`, `${packageName}/lib/${subpath}.js`, packageName]
  for (const anchor of anchors) {
    if (!existsSync(anchor)) continue
    const require = createRequire(anchor)
    for (const specifier of specifiers) {
      try {
        const resolved = require.resolve(specifier)
        if (existsSync(resolved)) return realpathSync(resolved)
      } catch {
        /* try next */
      }
    }
  }

  const pnpm = join(root, 'node_modules/.pnpm')
  const needle = packageName.replace('/', '+')
  if (existsSync(pnpm)) {
    for (const entry of readdirSync(pnpm)) {
      if (!entry.includes(needle)) continue
      const path = join(pnpm, entry, 'node_modules', ...packageName.split('/'), ...subpath.split('/'))
      if (existsSync(path)) return realpathSync(path)
    }
  }

  throw new Error(`${packageName} ${subpath} not found under ${root}`)
}
