import {realpath} from 'node:fs/promises';
import type {Context} from '@deepseek-ai/cordis';
import type {ActorContext} from 'workdsh-contracts';
import type {SessionInspection} from './session-cold-inspect.js';

/** create() is a new-conversation command: a named started Session causes the
 * official controller to mint another identity. Resume must use cold reads. */
export async function resumeWorkbenchCreationSession(actor:ActorContext,sessionId:string,expectedId:string,directory:string,
 ports:{authorize(actor:ActorContext,id:string,signal?:AbortSignal):Promise<void>;inspect(sessionId:string,signal?:AbortSignal):Promise<SessionInspection>;list:Context['sessionController']['list'];projections:Context['sessionController']['projections']},
 check:()=>void,signal?:AbortSignal){
 check();if(sessionId!==expectedId)throw Error('workbench/creation-conflict');
 await ports.authorize(actor,sessionId,signal);check();
 // Missing, unauthorized, corrupt and cancelled reads remain failures. None is
 // interpreted as permission to create or adopt another Session.
 const inspected=await ports.inspect(sessionId,signal);check();
 const listed=await ports.list({},signal??AbortSignal.timeout(60_000));check();
 const summary=listed.items.find(item=>String(item.sessionId)===String(sessionId));
 if(summary&&'origin' in summary&&(summary as {origin?:string}).origin==='subagent')throw Error('workbench/creation-conflict');
 if(!inspected.meta.cwd||await realpath(inspected.meta.cwd)!==directory)throw Error('workbench/session-workspace-mismatch');
 check();const projected=await ports.projections({sessionId:sessionId as never},signal??new AbortController().signal);check();
 if(projected?.kind!=='sequenced')throw Error('workbench/session-state-unavailable');
 if(projected.values.agentPreset!=='cordis')throw Error('workbench/development-creator-required');
 await ports.authorize(actor,sessionId,signal);check();
 return sessionId;
}
