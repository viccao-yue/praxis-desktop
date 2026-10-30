#!/usr/bin/env node
/**
 * The Remotion job log is a native disclosure that stretches to a full row
 * between the status and the project list, so it reads as another navigation
 * item. Keep status, log, and dismiss on one bar.
 *
 * Usage:
 *   node scripts/praxis/patch-remotion-job-bar.mjs <profile-root>
 *   node scripts/praxis/patch-remotion-job-bar.mjs --self-test
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '/* praxis-remotion-job-bar */'
const STATE = "const [job, setJob] = useState(cache.job), [busy, setBusy] = useState(false), [error, setError] = useState(''), [notice, setNotice] = useState(''), [pending, setPending] = useState(null), [conflict, setConflict] = useState(false);"
const STATE_NEXT = `${STATE} const [showLog, setShowLog] = useState(false); ${MARKER}`
const FROM = ` job ? h('div',{className:'media-job',role:job.state==='failed'?'alert':'status'},h('strong',null,t('任务状态：','Job status: ')+stage),job.url?h('a',{className:'w-button',href:job.url,target:'_blank',rel:'noopener noreferrer'},t('打开官方 Studio 预览','Open official Studio preview')):null,
 job.state==='running'?h(W.Button,{disabled:busy,onClick:()=>perform(async()=>{await api({action:'cancel',job:job.id});setNotice(t('已请求停止；正在关闭本次任务。','Stopping this job.'));})},job.kind==='preview'?t('停止预览，返回编辑','Stop preview and return to editing'):t('取消任务','Cancel job')):null,
 h('details',null,h('summary',null,t('查看运行记录','Show job log')),h('pre',null,job.lines.join('\\n')))) : null,`
const TO = ` job ? h('div',{className:'media-job',role:job.state==='failed'?'alert':'status'},h('div',{className:'media-job-row'},h('strong',null,t('任务状态：','Job status: ')+stage),h('span',{className:'media-job-actions'},job.url?h('a',{className:'w-button',href:job.url,target:'_blank',rel:'noopener noreferrer'},t('打开预览','Open preview')):null,job.state==='running'?h(W.Button,{disabled:busy,onClick:()=>perform(async()=>{await api({action:'cancel',job:job.id});setNotice(t('已请求停止；正在关闭本次任务。','Stopping this job.'));})},t('取消任务','Cancel')):null,job.lines.length?h('button',{type:'button',className:'media-job-log','aria-expanded':showLog,onClick:()=>setShowLog(open=>!open)},t(showLog?'收起记录':'运行记录',showLog?'Hide log':'Job log')):null,job.state!=='running'?h('button',{type:'button',className:'media-job-log',onClick:()=>{setShowLog(false);setJob(null);}},t('关闭','Dismiss')):null)),showLog&&job.lines.length?h('pre',{className:'media-job-lines'},job.lines.join('\\n')):null) : null,`
const OLD_CSS = '.media-job{color:var(--dsw-alias-label-secondary);font-size:13px}'
const NEW_CSS = `.media-job{display:flex;flex-direction:column;gap:8px;margin:0 0 16px;padding:10px 12px;border:0;border-radius:8px;background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-secondary);font-size:13px;line-height:22px}
.media-job-row{display:flex;align-items:center;gap:12px}
.media-job-row strong{font-weight:500;color:var(--dsw-alias-label-primary)}
.media-job-actions{display:flex;align-items:center;gap:4px;margin-left:auto}
.media-job-actions .w-button,.media-job-log{border:0;background:transparent;min-height:28px;padding:0 8px;border-radius:6px;color:var(--dsw-alias-label-secondary);font-size:13px;cursor:pointer}
.media-job-log:hover,.media-job-actions .w-button:hover{background:var(--dsw-alias-interactive-bg-hover);color:var(--dsw-alias-label-primary)}
.media-job-lines{margin:0;max-height:180px;overflow:auto;padding:8px 10px;border-radius:8px;background:var(--dsw-alias-bg-base);color:var(--dsw-alias-label-secondary);font:12px/20px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap}`

export function patchRemotionJobBarSource(source) {
  let next = source
  let changed = false
  if (!next.includes(MARKER)) {
    if (!next.includes(STATE) || !next.includes(FROM)) throw new Error('dsh-remotion job bar is missing; refuse to leave the run log as a separate row')
    next = next.replace(STATE, STATE_NEXT).replace(FROM, TO)
    changed = true
  } else if (next.includes("t('查看运行记录'")) {
    throw new Error('dsh-remotion job bar marker is present but the full-width log row remains')
  }
  if (next.includes(OLD_CSS)) {
    next = next.replace(OLD_CSS, NEW_CSS)
    changed = true
  } else if (!next.includes('.media-job-row{')) {
    throw new Error('dsh-remotion job bar styles are missing')
  }
  if (!next.includes(MARKER) || next.includes("t('查看运行记录'")) throw new Error('dsh-remotion job bar patch did not apply')
  return { source: next, changed, already: !changed }
}

export function patchRemotionJobBarAt(profile) {
  const path = join(profile, 'node_modules', 'dsh-remotion', 'lib', 'client.js')
  const patched = patchRemotionJobBarSource(readFileSync(path, 'utf8'))
  if (patched.changed) writeFileSync(path, patched.source)
  return { path, ...patched }
}

const invoked = process.argv[1]?.endsWith('patch-remotion-job-bar.mjs')
if (invoked && process.argv.includes('--self-test')) {
  const sample = `${STATE}\n${FROM}\n${OLD_CSS}`
  const once = patchRemotionJobBarSource(sample)
  if (!once.changed || !once.source.includes(MARKER) || once.source.includes("t('查看运行记录'") || !once.source.includes('.media-job-row{') || !once.source.includes('setShowLog')) {
    throw new Error('self-test did not fold the run log into the job status bar')
  }
  const twice = patchRemotionJobBarSource(once.source)
  if (!twice.already || twice.source !== once.source) throw new Error('self-test was not idempotent')
  let missing = false
  try { patchRemotionJobBarSource('no job bar') } catch { missing = true }
  if (!missing) throw new Error('self-test accepted an unknown remotion bundle')
  console.log('remotion job bar patch self-test ok')
} else if (invoked && process.argv[2] && !process.argv[2].startsWith('--')) {
  const result = patchRemotionJobBarAt(process.argv[2])
  console.log(result.already ? 'already' : 'patched', result.path)
}
