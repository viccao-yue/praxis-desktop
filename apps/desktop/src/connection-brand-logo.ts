/** Wordmark for carrier connection HTML. Path mirrors app-icon resolution from lib/. */
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

let cached: string | undefined

export function brandLogoDataUri(): string {
  if (cached) return cached
  const bytes = readFileSync(fileURLToPath(new URL('../build/connection-ui/praxis-wordmark.png', import.meta.url)))
  cached = `data:image/png;base64,${bytes.toString('base64')}`
  return cached
}
