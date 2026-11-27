import type { Context } from '@deepseek-ai/cordis';
import type { SessionId } from '@deepseek-ai/dsh-session';
import { inspectSession, type SessionInspection } from 'workdsh-plugin-access';

type ProtectedInspect = {
  inspect(sessionId: SessionId, signal?: AbortSignal): Promise<SessionInspection>;
};

/** Enterprise reads go through SessionAccessBridge; personal mode uses paginated cold read. */
export async function readSessionCold(
  controller: Pick<Context['sessionController'], 'events' | 'list'>,
  protectedSessions: ProtectedInspect | undefined,
  sessionId: SessionId,
  signal?: AbortSignal,
): Promise<SessionInspection> {
  if (protectedSessions) return protectedSessions.inspect(sessionId, signal);
  return inspectSession(controller, sessionId, signal);
}

export type { SessionInspection };