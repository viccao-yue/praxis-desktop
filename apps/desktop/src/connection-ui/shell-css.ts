/** Shared styles for the carrier connection surfaces. Kept as source text for reviewable diffs. */
export const shellCss = /* css */ `
:root {
  --brand: #2D5CF6;
  --brand-600: #1E4BDD;
  --brand-50: #F3F7FF;
  --ink: #0F172A;
  --ink-2: #475467;
  --muted: #6B7383;
  --faint: #98A1B2;
  --r: 10px;
  --ease: cubic-bezier(.22, .61, .36, 1);
}
* { box-sizing: border-box; margin: 0; padding: 0 }
html, body { height: 100% }
body {
  font-family: "Inter", -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", Arial, sans-serif;
  color: var(--ink);
  background: #fff;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
.shell {
  display: grid;
  grid-template-columns: minmax(400px, 43%) 1fr;
  min-height: 100vh;
}

.brand-panel {
  position: relative;
  overflow: hidden;
  background: var(--brand-50);
  display: flex;
  flex-direction: column;
  padding: 44px 56px 40px;
  border-right: 1px solid #E9EEF9;
}
.brand-panel::before {
  content: "";
  position: absolute;
  inset: 0;
  pointer-events: none;
  background-image:
    linear-gradient(to right, rgba(45, 92, 246, .075) 1px, transparent 1px),
    linear-gradient(to bottom, rgba(45, 92, 246, .075) 1px, transparent 1px);
  background-size: 72px 72px;
  mask-image: radial-gradient(120% 100% at 8% 0%, #000 0%, rgba(0, 0, 0, .45) 45%, transparent 78%);
  -webkit-mask-image: radial-gradient(120% 100% at 8% 0%, #000 0%, rgba(0, 0, 0, .45) 45%, transparent 78%);
}
.ring {
  position: absolute;
  border-radius: 50%;
  border: 1px solid rgba(45, 92, 246, .14);
  pointer-events: none;
}
.ring-1 { width: 520px; height: 520px; right: -230px; bottom: -240px }
.ring-2 { width: 340px; height: 340px; right: -140px; bottom: -150px; border-color: rgba(45, 92, 246, .09) }
.lockup { position: relative; z-index: 2 }
.brand-logo { display: block; height: 30px; width: auto }

.copy { position: relative; z-index: 2; margin: auto 0; padding: 24px 0 }
.eyebrow {
  display: flex;
  align-items: center;
  gap: 9px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: .14em;
  color: var(--brand);
}
.eyebrow i {
  display: block;
  width: 7px;
  height: 7px;
  background: var(--brand);
  border-radius: 1px;
}
.copy h1 {
  margin-top: 18px;
  font-size: 46px;
  line-height: 1.14;
  font-weight: 600;
  letter-spacing: .045em;
}
.copy .slogan {
  margin-top: 14px;
  font-size: 15px;
  line-height: 1.7;
  color: var(--ink-2);
  letter-spacing: .06em;
}
.feat { list-style: none; margin-top: 34px; max-width: 344px }
.feat li {
  position: relative;
  padding: 13px 0 13px 18px;
  font-size: 13.5px;
  letter-spacing: .02em;
  color: var(--ink-2);
  border-top: 1px solid #E3E9F6;
}
.feat li:last-child { border-bottom: 1px solid #E3E9F6 }
.feat li::before {
  content: "";
  position: absolute;
  left: 0;
  top: 50%;
  width: 6px;
  height: 6px;
  margin-top: -3px;
  background: var(--brand);
  border-radius: 1px;
  box-shadow: 0 0 0 3px rgba(45, 92, 246, .10);
}
.brand-foot {
  position: relative;
  z-index: 2;
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 11.5px;
  letter-spacing: .1em;
  color: #9AA5B8;
}
.brand-foot .dot {
  display: inline-block;
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: #16A34A;
  margin-right: 7px;
  vertical-align: middle;
  box-shadow: 0 0 0 3px rgba(22, 163, 74, .12);
}

.stage-side {
  position: relative;
  display: grid;
  place-items: center;
  padding: 56px 48px 72px;
}
.stage { width: 100%; max-width: 400px }
.screen { display: none }
.screen.is-active {
  display: block;
  animation: rise .42s var(--ease) both;
}
@keyframes rise {
  from { opacity: 0; transform: translateY(9px) }
  to { opacity: 1; transform: none }
}
.head { margin-bottom: 28px }
.head h2 {
  font-size: 25px;
  font-weight: 600;
  letter-spacing: -.01em;
  line-height: 1.25;
}
.head p {
  margin-top: 9px;
  font-size: 13.5px;
  line-height: 1.65;
  color: var(--muted);
}

.options { display: grid; gap: 10px; margin-bottom: 22px }
.option {
  position: relative;
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 15px 16px;
  background: #FBFCFE;
  border: 1px solid #E4EAF6;
  border-radius: var(--r);
  cursor: pointer;
  transition: border-color .16s var(--ease), background .16s var(--ease), box-shadow .16s var(--ease);
}
.option:hover { border-color: #CFDAF0; background: #FAFBFF }
.option input { position: absolute; opacity: 0; pointer-events: none }
.option .txt { flex: 1; min-width: 0 }
.option strong {
  display: block;
  font-size: 14px;
  font-weight: 600;
  color: var(--ink);
  letter-spacing: .01em;
}
.option small {
  display: block;
  margin-top: 5px;
  font-size: 12.5px;
  line-height: 1.55;
  color: var(--muted);
}
.option .radio {
  flex: none;
  width: 16px;
  height: 16px;
  margin-top: 2px;
  border-radius: 50%;
  border: 1.5px solid #C9D4EA;
  background: #fff;
  position: relative;
  transition: border-color .16s var(--ease);
}
.option .radio::after {
  content: "";
  position: absolute;
  inset: 3px;
  border-radius: 50%;
  background: var(--brand);
  opacity: 0;
  transform: scale(.6);
  transition: opacity .16s var(--ease), transform .16s var(--ease);
}
.option:has(input:checked) {
  border-color: var(--brand);
  background: #F7FAFF;
  box-shadow: 0 0 0 3px rgba(45, 92, 246, .09);
}
.option:has(input:checked) .radio { border-color: var(--brand) }
.option:has(input:checked) .radio::after { opacity: 1; transform: scale(1) }
.option input:focus-visible ~ .radio { box-shadow: 0 0 0 3px rgba(45, 92, 246, .2) }
.option.is-disabled {
  opacity: .55;
  cursor: not-allowed;
  pointer-events: none;
}

.field { margin-bottom: 18px }
.field label {
  display: block;
  font-size: 12.5px;
  font-weight: 500;
  color: var(--ink-2);
  margin-bottom: 8px;
  letter-spacing: .02em;
}
.control { position: relative }
.control input {
  width: 100%;
  height: 46px;
  padding: 0 14px;
  font-family: inherit;
  font-size: 14px;
  color: var(--ink);
  background: #F7F9FE;
  border: 1px solid #E4EAF6;
  border-radius: var(--r);
  outline: none;
  transition: border-color .18s var(--ease), box-shadow .18s var(--ease), background .18s var(--ease);
}
.control input::placeholder { color: #B4BCCB }
.control input:hover { border-color: #CFDAF0 }
.control input:focus {
  background: #fff;
  border-color: var(--brand);
  box-shadow: 0 0 0 3px rgba(45, 92, 246, .13);
}
.control input.mono {
  font-family: "SF Mono", ui-monospace, Menlo, monospace;
  font-size: 13px;
  letter-spacing: -.01em;
}
.control.has-action input { padding-right: 46px }
.reveal {
  position: absolute;
  right: 6px;
  top: 50%;
  transform: translateY(-50%);
  width: 34px;
  height: 34px;
  display: grid;
  place-items: center;
  background: none;
  border: 0;
  border-radius: 8px;
  cursor: pointer;
  color: var(--faint);
  transition: color .15s var(--ease), background .15s var(--ease);
}
.reveal:hover { color: var(--ink-2); background: #EEF2FB }

.managed-portal {
  margin: 0;
  padding: 12px 14px;
  background: #F7F9FE;
  border: 1px solid #E4EAF6;
  border-radius: var(--r);
  font-family: "SF Mono", ui-monospace, Menlo, monospace;
  font-size: 13px;
  color: var(--ink-2);
  word-break: break-all;
}
.plugin-hint {
  margin-top: 14px;
  font-size: 12.5px;
  line-height: 1.55;
  color: var(--muted);
}
.field.is-invalid input {
  border-color: #E5533D;
  background: #FEF6F4;
}
.status {
  display: none;
  margin: 0 0 18px;
  padding: 11px 13px;
  border-radius: 8px;
  font-size: 13px;
  line-height: 1.5;
}
.status.is-on { display: flex; align-items: flex-start; gap: 9px }
.status.is-error {
  background: #FDF1EE;
  border: 1px solid #F7DCD5;
  color: #B4362A;
}
.status.is-info {
  background: #F3F7FF;
  border: 1px solid #D9E4FF;
  color: var(--ink-2);
}
.status svg { flex: none; margin-top: 1px }

.submit {
  width: 100%;
  height: 48px;
  font-family: inherit;
  font-size: 15px;
  font-weight: 600;
  letter-spacing: .05em;
  color: #fff;
  background: var(--brand);
  border: 0;
  border-radius: var(--r);
  cursor: pointer;
  transition: background .18s var(--ease), box-shadow .18s var(--ease), transform .1s var(--ease);
}
.submit:hover {
  background: var(--brand-600);
  box-shadow: 0 8px 22px rgba(45, 92, 246, .26);
}
.submit:active {
  transform: translateY(1px);
  box-shadow: 0 3px 10px rgba(45, 92, 246, .2);
}
.submit:focus-visible {
  outline: none;
  box-shadow: 0 0 0 3px rgba(45, 92, 246, .28);
}
.submit:disabled,
.submit:disabled:hover {
  opacity: .55;
  cursor: not-allowed;
  box-shadow: none;
  transform: none;
  background: var(--brand);
}
a.submit {
  display: grid;
  place-items: center;
  text-decoration: none;
}
.shell:has(input[value="personal"]:checked) .enterprise-continue { display: none }
.shell:has(input[value="enterprise"]:checked) .personal-continue { display: none }

.back {
  display: block;
  margin-top: 16px;
  text-align: center;
  font-size: 12.5px;
  color: var(--muted);
  text-decoration: none;
}
.back:hover { color: var(--brand) }

.server {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: -4px 0 22px;
  padding: 9px 12px;
  background: #F7F9FE;
  border: 1px solid #E9EEF9;
  border-radius: 8px;
  font-size: 12px;
  color: var(--ink-2);
}
.server .lamp {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: #16A34A;
  flex: none;
  box-shadow: 0 0 0 3px rgba(22, 163, 74, .12);
}
.server code {
  font-family: "SF Mono", ui-monospace, Menlo, monospace;
  font-size: 12px;
  color: var(--ink-2);
}
.server .switch {
  margin-left: auto;
  font-size: 12px;
  color: var(--brand);
  text-decoration: none;
  white-space: nowrap;
}
.server .switch:hover { text-decoration: underline }

.track {
  height: 4px;
  background: #EDF1FA;
  border-radius: 99px;
  overflow: hidden;
  position: relative;
  margin: 24px 0 4px;
}
.track::after {
  content: "";
  position: absolute;
  top: 0;
  bottom: 0;
  width: 36%;
  border-radius: 99px;
  background: var(--brand);
  animation: slide 1.5s cubic-bezier(.45, 0, .55, 1) infinite;
}
@keyframes slide {
  0% { left: -38% }
  100% { left: 100% }
}
.steps { list-style: none; margin-top: 20px }
.steps li {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 8px 0;
  font-size: 13px;
  color: #A6AEBE;
}
.steps li .d {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: #DCE3F2;
  flex: none;
}
.steps li:nth-child(1) { color: var(--ink) }
.steps li:nth-child(1) .d {
  background: var(--brand);
  box-shadow: 0 0 0 4px rgba(45, 92, 246, .14);
}

@media (prefers-reduced-motion: reduce) {
  .screen.is-active { animation: none }
  .track::after { animation: none }
  * { transition-duration: .001s !important }
}
@media (max-width: 960px) {
  .shell { grid-template-columns: 1fr }
  .brand-panel {
    padding: 30px 28px;
    border-right: 0;
    border-bottom: 1px solid #E9EEF9;
  }
  .copy { margin: 0; padding: 32px 0 2px }
  .copy h1 { font-size: 32px }
  .feat, .brand-foot { display: none }
  .stage-side {
    padding: 36px 28px 76px;
    align-items: start;
  }
}
`
