#!/usr/bin/env node
/** Package an external workbench plugin for manual import (插件 → 添加插件). */
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { basename, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('../', import.meta.url)))
const project = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
const sourceArg = process.argv.find(arg => arg.startsWith('--archive='))
const archive = sourceArg ? resolve(sourceArg.slice('--archive='.length)) : resolve(process.argv[2] ?? '')
const output = resolve(process.argv[3] ?? join(root, '.artifacts/workbench-short-video-studio-release'))
if (!archive || !existsSync(archive)) {
  throw new Error('Usage: node scripts/pack-short-video-studio-release.mjs --archive=/path/to/workdsh-workbench-short-video-studio.tgz [outputDir]')
}
mkdirSync(output, { recursive: true })
const bytes = readFileSync(archive)
const pkg = JSON.parse(execFileSync('tar', ['-xOzf', archive, 'package/package.json'], { encoding: 'utf8' }))
const filename = `${pkg.name}-${pkg.version}.tgz`
const sha256 = createHash('sha256').update(bytes).digest('hex')
writeFileSync(join(output, filename), bytes)
writeFileSync(join(output, 'SHA256SUMS.txt'), `${sha256}  ${filename}\n`)
writeFileSync(join(output, 'release-manifest.json'), JSON.stringify({
  kind: 'workdsh-external-workbench-plugin',
  name: pkg.name,
  version: pkg.version,
  harness: project.devDependencies?.['@deepseek-ai/dsh'] ?? project.dependencies?.['@deepseek-ai/dsh'],
  filename,
  bytes: bytes.length,
  sha256,
  install: '桌面端：设置 → 插件 → 添加插件 → 选择 TGZ 文件。安装后在工作台列表中启用。',
  peerDependencies: pkg.peerDependencies ?? {},
}, null, 2) + '\n')
writeFileSync(join(output, 'INSTALL.zh-CN.md'), `# ${pkg.name} 独立安装包

- 版本：${pkg.version}
- 文件：\`${filename}\`
- SHA256：\`${sha256}\`

## 安装

1. 打开开物 Praxis 个人工作区（需已包含 \`workdsh-plugin-workbenches\`）。
2. 进入 **设置 → 插件 → 添加插件**。
3. 选择本目录中的 \`${filename}\`。
4. 安装完成后在插件列表中启用，并在工作台中打开「短视频工作室」。

本包不会随基础安装包预装，避免拖慢个人区启动。
`)
console.log(`Short-video studio delivery: ${join(output, filename)} (${bytes.length} bytes)`)
