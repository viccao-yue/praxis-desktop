/** Copy pnpm-only packages onto the Profile root as real directories.
 * Windows NSIS drops junctions inside `.pnpm/.../node_modules`. Node then
 * walks up to the Profile root. A root copy keeps `plugin install` from
 * failing with ERR_MODULE_NOT_FOUND one package at a time. */
import { cpSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'

function packageVersion(directory) {
  try { return JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8')).version || '0.0.0' }
  catch { return '0.0.0' }
}

function versionGreater(left, right) {
  const a = String(left).split('.')
  const b = String(right).split('.')
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const av = Number.parseInt(a[i] ?? '0', 10)
    const bv = Number.parseInt(b[i] ?? '0', 10)
    if (Number.isNaN(av) || Number.isNaN(bv)) return String(left) > String(right)
    if (av !== bv) return av > bv
  }
  return false
}

function consider(chosen, modulesDir, relativeName, source) {
  if (existsSync(join(modulesDir, relativeName))) return
  let real
  try { real = realpathSync(source) } catch { return }
  if (!existsSync(join(real, 'package.json'))) return
  const version = packageVersion(real)
  const current = chosen.get(relativeName)
  if (!current || versionGreater(version, current.version)) chosen.set(relativeName, { real, version })
}

export function materializeMissingRootPackages(modulesDir) {
  const pnpmDir = join(modulesDir, '.pnpm')
  if (!existsSync(pnpmDir)) return 0
  const chosen = new Map()
  for (const store of readdirSync(pnpmDir)) {
    const inner = join(pnpmDir, store, 'node_modules')
    if (!existsSync(inner)) continue
    for (const name of readdirSync(inner)) {
      if (name === '.bin' || name.startsWith('.')) continue
      const source = join(inner, name)
      let scoped = false
      try { scoped = name.startsWith('@') && !lstatSync(source).isSymbolicLink() } catch { continue }
      if (scoped) {
        for (const child of readdirSync(source)) consider(chosen, modulesDir, join(name, child), join(source, child))
      } else {
        consider(chosen, modulesDir, name, source)
      }
    }
  }
  for (const [relativeName, { real }] of chosen) {
    const destination = join(modulesDir, relativeName)
    mkdirSync(dirname(destination), { recursive: true })
    cpSync(real, destination, {
      recursive: true,
      dereference: true,
      filter: source => source === real || basename(source) !== 'node_modules',
    })
  }
  const execa = join(modulesDir, 'execa', 'package.json')
  if (!existsSync(execa)) throw new Error('Windows-safe Profile root is missing execa')
  return chosen.size
}
