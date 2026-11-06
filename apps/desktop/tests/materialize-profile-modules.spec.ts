import { lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
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
    expect(lstatSync(join(dir, 'commander')).isSymbolicLink()).toBe(false)
  })

  it('replaces a hoisted symlink into .pnpm with the selected real package', () => {
    const dir = modules()
    const excel = join(dir, '.pnpm', 'exceljs@4.4.0', 'node_modules', 'exceljs')
    const newer = join(dir, '.pnpm', 'exceljs@5.0.0', 'node_modules', 'exceljs')
    const execa = join(dir, '.pnpm', 'execa@10.2.1', 'node_modules', 'execa')
    for (const directory of [excel, newer, execa]) mkdirSync(directory, { recursive: true })
    writeFileSync(join(excel, 'package.json'), JSON.stringify({ name: 'exceljs', version: '4.4.0' }))
    writeFileSync(join(excel, 'index.js'), 'export {}\n')
    writeFileSync(join(newer, 'package.json'), JSON.stringify({ name: 'exceljs', version: '5.0.0' }))
    writeFileSync(join(execa, 'package.json'), JSON.stringify({ name: 'execa', version: '10.2.1' }))
    symlinkSync(excel, join(dir, 'exceljs'), 'dir')

    materializeMissingRootPackages(dir)
    const placed = join(dir, 'exceljs')
    expect(lstatSync(placed).isSymbolicLink()).toBe(false)
    expect(JSON.parse(readFileSync(join(placed, 'package.json'), 'utf8')).version).toBe('4.4.0')
    expect(readFileSync(join(excel, 'index.js'), 'utf8')).toContain('export')
  })

  it('keeps a private dependency version beside the package that selected it', () => {
    const dir = modules()
    const excel = join(dir, '.pnpm', 'exceljs@4.4.0', 'node_modules', 'exceljs')
    const signal3 = join(dir, '.pnpm', 'signal-exit@3.0.7', 'node_modules', 'signal-exit')
    const signal4 = join(dir, '.pnpm', 'signal-exit@4.1.0', 'node_modules', 'signal-exit')
    const execa = join(dir, '.pnpm', 'execa@10.2.1', 'node_modules', 'execa')
    for (const directory of [excel, signal3, signal4, execa]) mkdirSync(directory, { recursive: true })
    writeFileSync(join(excel, 'package.json'), JSON.stringify({ name: 'exceljs', version: '4.4.0' }))
    writeFileSync(join(signal3, 'package.json'), JSON.stringify({ name: 'signal-exit', version: '3.0.7' }))
    writeFileSync(join(signal3, 'index.js'), 'module.exports = function onExit() {}\n')
    writeFileSync(join(signal4, 'package.json'), JSON.stringify({ name: 'signal-exit', version: '4.1.0' }))
    writeFileSync(join(execa, 'package.json'), JSON.stringify({ name: 'execa', version: '10.2.1' }))
    symlinkSync(signal3, join(dir, '.pnpm', 'exceljs@4.4.0', 'node_modules', 'signal-exit'), 'dir')
    symlinkSync(excel, join(dir, 'exceljs'), 'dir')
    symlinkSync(signal4, join(dir, 'signal-exit'), 'dir')

    materializeMissingRootPackages(dir)
    expect(JSON.parse(readFileSync(join(dir, 'signal-exit', 'package.json'), 'utf8')).version).toBe('4.1.0')
    expect(lstatSync(join(dir, 'signal-exit')).isSymbolicLink()).toBe(false)
    const nested = join(dir, 'exceljs', 'node_modules', 'signal-exit', 'package.json')
    expect(JSON.parse(readFileSync(nested, 'utf8')).version).toBe('3.0.7')
    expect(readFileSync(join(signal3, 'index.js'), 'utf8')).toContain('onExit')
  })

  it('stops when two private packages depend on each other', () => {
    const dir = modules()
    const left = join(dir, '.pnpm', 'left@1.0.0', 'node_modules', 'left')
    const right = join(dir, '.pnpm', 'right@1.0.0', 'node_modules', 'right')
    const execa = join(dir, '.pnpm', 'execa@10.2.1', 'node_modules', 'execa')
    for (const directory of [left, right, execa]) mkdirSync(directory, { recursive: true })
    writeFileSync(join(left, 'package.json'), JSON.stringify({ name: 'left', version: '1.0.0' }))
    writeFileSync(join(right, 'package.json'), JSON.stringify({ name: 'right', version: '1.0.0' }))
    writeFileSync(join(execa, 'package.json'), JSON.stringify({ name: 'execa', version: '10.2.1' }))
    symlinkSync(right, join(dir, '.pnpm', 'left@1.0.0', 'node_modules', 'right'), 'dir')
    symlinkSync(left, join(dir, '.pnpm', 'right@1.0.0', 'node_modules', 'left'), 'dir')

    expect(materializeMissingRootPackages(dir)).toBe(3)
    expect(JSON.parse(readFileSync(join(dir, 'left', 'node_modules', 'right', 'package.json'), 'utf8')).version).toBe('1.0.0')
    expect(JSON.parse(readFileSync(join(dir, 'right', 'node_modules', 'left', 'package.json'), 'utf8')).version).toBe('1.0.0')
  })
})
