export function patchNativeWorkbenchFrame(source: string): string
export function recoverOriginalWorkbenchFrameSource(
  source: string,
  locks?: {
    replacements: readonly (readonly [string, string])[]
    originalSha256: string
    patchedSha256: string
  },
): string
export function ensureNativeWorkbenchFrame(profile: string, options?: { rollback?: boolean }): Promise<void>
export function verifyNativeWorkbenchFrame(profile: string): Promise<{
  package: string; version: string; file: string; sha256: string
}>
export function recomputeNativeWorkbenchFrameSpec(
  profile: string,
  options?: { write?: boolean },
): Promise<{
  package: string
  version: string
  file: string
  originalSha256: string
  patchedSha256: string
  replacements: readonly (readonly [string, string])[]
}>
