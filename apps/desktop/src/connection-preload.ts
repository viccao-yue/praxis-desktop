/** Only the carrier's own login document receives this preload. No member token API. */
import { ipcRenderer } from 'electron'

window.addEventListener('DOMContentLoaded', () => {
  const form = document.querySelector<HTMLFormElement>('#enterprise-login')
  const status = document.querySelector<HTMLElement>('#status')
  const statusBox = document.querySelector<HTMLElement>('#status-box')
  const accountField = document.querySelector<HTMLElement>('#f-account')
  const passwordField = document.querySelector<HTMLElement>('#f-password')
  const account = document.querySelector<HTMLInputElement>('#account')
  const password = document.querySelector<HTMLInputElement>('#password')
  const reveal = document.querySelector<HTMLButtonElement>('#reveal')
  const slash = document.querySelector<SVGElement>('#slash')
  if (password && reveal) {
    reveal.addEventListener('click', () => {
      const show = password.type === 'password'
      password.type = show ? 'text' : 'password'
      if (slash) slash.toggleAttribute('hidden', !show)
      reveal.setAttribute('aria-pressed', String(show))
      reveal.setAttribute('aria-label', show ? '隐藏密码' : '显示密码')
    })
  }
  if (!form || !status) return
  let busy = false
  const clearInvalid = (): void => {
    accountField?.classList.remove('is-invalid')
    passwordField?.classList.remove('is-invalid')
  }
  const setStatus = (message: string, kind: 'error' | 'info' | 'clear'): void => {
    status.textContent = message
    if (!statusBox) return
    statusBox.classList.toggle('is-on', kind !== 'clear' && message.length > 0)
    statusBox.classList.toggle('is-error', kind === 'error')
    statusBox.classList.toggle('is-info', kind === 'info')
    if (kind === 'error') {
      accountField?.classList.add('is-invalid')
      passwordField?.classList.add('is-invalid')
    } else {
      clearInvalid()
    }
  }
  for (const input of [account, password]) {
    input?.addEventListener('input', () => {
      if (statusBox?.classList.contains('is-on')) setStatus('', 'clear')
    })
  }
  const perform = async (value: { account: string, password: string }): Promise<void> => {
    if (busy) return
    busy = true
    setStatus('正在核验企业账号并准备本机运行…', 'info')
    for (const button of form.querySelectorAll('button')) button.disabled = true
    try {
      const result = await ipcRenderer.invoke('kaiwu:enterprise-login', value) as { error?: string }
      if (result.error) setStatus(result.error, 'error')
      else setStatus('正在启动本机官方 DSH…', 'info')
    } catch { setStatus('无法完成操作，请返回入口后重试', 'error') }
    finally {
      busy = false
      for (const button of form.querySelectorAll('button')) button.disabled = false
    }
  }
  form.addEventListener('submit', event => {
    event.preventDefault()
    const accountInput = document.querySelector<HTMLInputElement>('#account')!
    const nextPassword = document.querySelector<HTMLInputElement>('#password')!
    if (!accountInput.value.trim() || !nextPassword.value) {
      setStatus('请输入账号和密码', 'error')
      accountField?.classList.toggle('is-invalid', !accountInput.value.trim())
      passwordField?.classList.toggle('is-invalid', !nextPassword.value)
      return
    }
    const value = { account: accountInput.value, password: nextPassword.value }
    nextPassword.value = ''
    void perform(value)
  })
})
