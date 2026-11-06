import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { materializeMissingRootPackages } from '../scripts/materialize-profile-modules.mjs'

const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function modules(): string {
  const root = mkdtempSync(join(tmpdir(), 'profile-modules-'))
  roots.push(root)
  return join(root, 'node_modules')
}

describe('materializeMissingRootPackages', () => {
  it('copies a pnpm-only package to the Profile root', () => {
    const dir = modules()
    const execa = join(dir, '.pnpm', 'execa@10.2.1', 'node_modules', 'execa')
    mkdirSync(join(execa, 'node_modules', 'nested'), { recursive: true })
    writeFileSync(join(execa, 'package.json'), JSON.stringify({ name: 'execa', version: '10.2.1' }))
    writeFileSync(join(execa, 'index.js'), 'export {}\n')
    writeFileSync(join(execa, 'node_modules', 'nested', 'package.json'), '{"name":"nested"}')

    expect(materializeMissingRootPackages(dir)).toBe(1)
    expect(JSON.parse(readFileSync(join(dir, 'execa', 'package.json'), 'utf8')).version).toBe('10.2.1')
    expect(readFileSync(join(dir, 'execa', 'index.js'), 'utf8')).toContain('export')
  })

  it('keeps the higher version and does not replace a root entry', () => {
    const dir = modules()
    for (const version of ['8.0.0', '10.2.1']) {
      const execa = join(dir, '.pnpm', `execa@${version}`, 'node_modules', 'execa')
      mkdirSync(execa, { recursive: true })
      writeFileSync(join(execa, 'package.json'), JSON.stringify({ name: 'execa', version }))
    }
    const kept = join(dir, 'commander')
    mkdirSync(kept, { recursive: true })
    writeFileSync(join(kept, 'package.json'), JSON.stringify({ name: 'commander', version: '15.0.0' }))
    symlinkSync(kept, join(dir, '.pnpm', 'commander-link'), 'dir')

    materializeMissingRootPackages(dir)
    expect(JSON.parse(readFileSync(join(dir, 'execa', 'package.json'), 'utf8')).version).toBe('10.2.1')
    expect(JSON.parse(readFileSync(join(dir, 'commander', 'package.json'), 'utf8')).version).toBe('15.0.0')
  })
})
