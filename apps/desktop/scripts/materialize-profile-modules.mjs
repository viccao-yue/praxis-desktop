/** Copy Profile packages onto the root as real directories.
 * Windows NSIS drops junctions and symlinks into `.pnpm`. Node then walks up
 * to the Profile root. A root symlink still counts as present to `existsSync`,
 * so it used to be skipped and disappeared after install. Packages such as
 * exceljs and saxes are loaded that way; without them the library host never
 * starts and its sidebar entry cannot open a panel. */
import { cpSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, unlinkSync } from 'node:fs'
import { basename, dirname, join, sep } from 'node:path'

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

function insidePnpm(modulesDir, real) {
  const pnpm = realpathSync(join(modulesDir, '.pnpm'))
  const prefix = pnpm.endsWith(sep) ? pnpm : pnpm + sep
  return real === pnpm || real.startsWith(prefix)
}

/** The hoisted path pnpm actually selected, when it is only a link into `.pnpm`. */
function linkedReal(modulesDir, relativeName, cache) {
  if (cache.has(relativeName)) return cache.get(relativeName)
  const destination = join(modulesDir, relativeName)
  let real = null
  try {
    if (existsSync(destination)) {
      const resolved = realpathSync(destination)
      if (insidePnpm(modulesDir, resolved)) real = resolved
    }
  } catch { real = null }
  cache.set(relativeName, real)
  return real
}

function removeLink(path) {
  if (lstatSync(path).isSymbolicLink()) {
    unlinkSync(path)
    return
  }
  // A Windows junction is a directory reparse point. Removing it without
  // recursion deletes the link and leaves the `.pnpm` target in place.
  rmSync(path, { recursive: false, force: true })
}

function copyPackageBody(real, destination) {
  mkdirSync(dirname(destination), { recursive: true })
  cpSync(real, destination, {
    recursive: true,
    dereference: true,
    filter: source => source === real || basename(source) !== 'node_modules',
  })
}

function packageRelative(real) {
  const parent = dirname(real)
  if (basename(parent).startsWith('@') && basename(dirname(parent)) === 'node_modules') return join(basename(parent), basename(real))
  return basename(real)
}

/** Packages pnpm placed beside this one inside a single `.pnpm` virtual store. */
function virtualSiblings(real) {
  const own = packageRelative(real)
  const store = own === basename(real) ? dirname(real) : dirname(dirname(real))
  if (basename(store) !== 'node_modules') return []
  const found = []
  let names
  try { names = readdirSync(store) } catch { return found }
  for (const name of names) {
    if (name === '.bin' || name.startsWith('.')) continue
    const source = join(store, name)
    let scoped = false
    try { scoped = name.startsWith('@') && !lstatSync(source).isSymbolicLink() } catch { continue }
    if (scoped) {
      for (const child of readdirSync(source)) {
        const relativeName = join(name, child)
        if (relativeName !== own) found.push([relativeName, join(source, child)])
      }
    } else if (name !== own) found.push([name, source])
  }
  return found
}

/** Keep a dependency that is not the hoisted root copy next to its importer.
 * Flattening every package onto one version makes `signal-exit` 4 replace the
 * function export that `proper-lockfile` loads from 3.x.
 * Only one nesting level: walking every private tree recursively copies the
 * whole store under each importer and OOMs electron-builder / times out CI. */
function embedPrivateDependencies(real, destination, hoistedReal) {
  for (const [relativeName, source] of virtualSiblings(real)) {
    let depReal
    try { depReal = realpathSync(source) } catch { continue }
    if (!existsSync(join(depReal, 'package.json'))) continue
    if (hoistedReal.get(relativeName) === depReal) continue
    const depDestination = join(destination, 'node_modules', relativeName)
    if (!existsSync(join(depDestination, 'package.json'))) copyPackageBody(depReal, depDestination)
  }
}

function consider(chosen, modulesDir, relativeName, source, linkCache) {
  const pinned = linkedReal(modulesDir, relativeName, linkCache)
  if (pinned) {
    if (!chosen.get(relativeName)?.pinned) chosen.set(relativeName, { real: pinned, version: packageVersion(pinned), pinned: true })
    return
  }
  if (existsSync(join(modulesDir, relativeName))) return
  let real
  try { real = realpathSync(source) } catch { return }
  if (!existsSync(join(real, 'package.json'))) return
  const version = packageVersion(real)
  const current = chosen.get(relativeName)
  if (!current || versionGreater(version, current.version)) chosen.set(relativeName, { real, version, pinned: false })
}

export function materializeMissingRootPackages(modulesDir) {
  const pnpmDir = join(modulesDir, '.pnpm')
  if (!existsSync(pnpmDir)) return 0
  const chosen = new Map()
  const linkCache = new Map()
  for (const store of readdirSync(pnpmDir)) {
    const inner = join(pnpmDir, store, 'node_modules')
    if (!existsSync(inner)) continue
    for (const name of readdirSync(inner)) {
      if (name === '.bin' || name.startsWith('.')) continue
      const source = join(inner, name)
      let scoped = false
      try { scoped = name.startsWith('@') && !lstatSync(source).isSymbolicLink() } catch { continue }
      if (scoped) {
        for (const child of readdirSync(source)) consider(chosen, modulesDir, join(name, child), join(source, child), linkCache)
      } else {
        consider(chosen, modulesDir, name, source, linkCache)
      }
    }
  }
  const hoistedReal = new Map()
  for (const [relativeName, entry] of chosen) if (entry.pinned) hoistedReal.set(relativeName, entry.real)
  for (const [relativeName, { real, pinned }] of chosen) {
    const destination = join(modulesDir, relativeName)
    if (pinned) removeLink(destination)
    copyPackageBody(real, destination)
    embedPrivateDependencies(real, destination, hoistedReal)
  }
  const execa = join(modulesDir, 'execa', 'package.json')
  if (!existsSync(execa)) throw new Error('Windows-safe Profile root is missing execa')
  return chosen.size
}
