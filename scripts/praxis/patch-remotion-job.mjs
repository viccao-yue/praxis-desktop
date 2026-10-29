#!/usr/bin/env node
/**
 * remotion_render action "job" reads the task id from `job`. Agents pass the
 * project id in `id`, and mediaId(undefined) reports that as an invalid id.
 * Accept a real task id in either field. When that id is a project id and
 * exactly one task is running, return that task instead of failing.
 *
 * Usage:
 *   node scripts/praxis/patch-remotion-job.mjs <profile-root>
 *   node scripts/praxis/patch-remotion-job.mjs --self-test
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-remotion-job */'
const FROM = `                    case 'job':
                        value = this.job(mediaId(v.job));
                        break;
                    case 'cancel':
                        value = this.cancel(mediaId(v.job));
                        break;`
const TO = `                    case 'job':
                    case 'cancel': {
                        ${MARKER}
                        const key = typeof v.job === 'string' ? v.job : v.id;
                        const valid = typeof key === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(key);
                        let found = valid ? this.jobs.get(key) : undefined;
                        if (!found && v.action === 'job') {
                            const running = [...this.jobs.values()].filter(j => j.view.state === 'running');
                            if (running.length === 1) found = running[0];
                        }
                        if (!found) {
                            const listed = [...this.jobs.values()].map(j => j.view.id + '（' + j.view.kind + ' ' + j.view.state + '）');
                            throw new Error('这不是任务编号。查询或取消请把 prepare、preview 或 render 返回的 id 放在 job 字段，工程编号不能当作任务编号。' + (listed.length ? '当前任务：' + listed.join('，') : '当前没有任务记录；若刚重启过，请重新 prepare。'));
                        }
                        value = v.action === 'cancel' ? this.cancel(found.view.id) : this.job(found.view.id);
                        break;
                    }`
const OLD_DESC = '准备官方渲染环境、启动预览/MP4任务、查询进度或取消。工程保存在 DSH 本地数据目录；首次准备环境会下载依赖。'
const NEW_DESC = '准备官方渲染环境、启动预览或 MP4、查询进度或取消。id 是工程编号，只给 preview 和 render。prepare、preview、render 返回的 id 才是任务编号，查询和取消时放在 job 字段。工程编号不能传给 action job。'

export function patchRemotionJobSource(source) {
  let next = source
  let changed = false
  if (!next.includes(MARKER)) {
    if (!next.includes(FROM)) throw new Error('dsh-remotion job switch is missing; refuse to leave project ids queried as tasks')
    next = next.replace(FROM, TO)
    changed = true
  } else if (next.includes('value = this.job(mediaId(v.job))')) {
    throw new Error('dsh-remotion job marker is present but the old job lookup remains')
  }
  if (next.includes(OLD_DESC)) {
    next = next.replace(OLD_DESC, NEW_DESC)
    changed = true
  }
  if (!next.includes(MARKER) || !next.includes(NEW_DESC)) throw new Error('dsh-remotion job patch did not apply')
  return { source: next, changed, already: !changed }
}

export function patchRemotionJobAt(profile) {
  const path = join(profile, 'node_modules', 'dsh-remotion', 'lib', 'media-workbench.js')
  const patched = patchRemotionJobSource(readFileSync(path, 'utf8'))
  if (patched.changed) writeFileSync(path, patched.source)
  return { path, ...patched }
}

const invoked = process.argv[1]?.endsWith('patch-remotion-job.mjs')
if (invoked && process.argv.includes('--self-test')) {
  const sample = `${FROM}\n${OLD_DESC}`
  const once = patchRemotionJobSource(sample)
  if (!once.changed || !once.source.includes(MARKER) || once.source.includes('mediaId(v.job)') || !once.source.includes(NEW_DESC)) {
    throw new Error('self-test did not accept a task id separately from the project id')
  }
  const twice = patchRemotionJobSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  let missing = false
  try { patchRemotionJobSource('no job switch') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown remotion bundle')
  console.log('remotion job id patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  const result = patchRemotionJobAt(process.argv[2])
  console.log(result.already ? 'already' : 'patched', result.path)
}
