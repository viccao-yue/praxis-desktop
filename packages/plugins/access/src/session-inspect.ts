import type { Context } from '@deepseek-ai/cordis'
import type { SessionId } from '@deepseek-ai/dsh-session'
import type { SessionEvent } from '@deepseek-ai/dsh-session'
import { ApiSessionNotFound } from '@deepseek-ai/dsh-api-session-controller'

/** Cold Session inspection shaped like the retired sessionController.inspect result. */
export type SessionInspection = {
  events: readonly SessionEvent[]
  meta: { cwd?: string }
}

type SessionController = Context['sessionController']

/**
 * Reconstruct a full cold Session read on DSH 0.2.2+, where inspect() was removed
 * in favor of paginated events() plus SessionSummary.cwd.
 */
export async function inspectSession(
  controller: Pick<SessionController, 'events' | 'list'>,
  sessionId: SessionId,
  signal?: AbortSignal,
): Promise<SessionInspection> {
  const abort = signal ?? AbortSignal.timeout(60_000)
  abort.throwIfAborted()
  const collected: SessionEvent[] = []
  let beforeSeq: number | undefined
  for (let page = 0; page < 64; page += 1) {
    const batch = await controller.events({
      address: { kind: 'session', sessionId },
      maxMessages: 200,
      ...(beforeSeq === undefined ? {} : { beforeSeq }),
    }, abort)
    abort.throwIfAborted()
    const events = batch.records.map(record => record.event as unknown as SessionEvent)
    if (!events.length) break
    // events() returns one chronological page; beforeSeq walks toward older history.
    collected.unshift(...events)
    if (!batch.hasMore) break
    beforeSeq = events[0]!.seq
  }

  const listed = await controller.list({}, abort)
  abort.throwIfAborted()
  const summary = listed.items.find(item => String(item.sessionId) === String(sessionId))
  if (!summary && !collected.length) throw new ApiSessionNotFound(`Session not found: ${String(sessionId)}`)
  return { events: collected, meta: { cwd: summary?.cwd } }
}
