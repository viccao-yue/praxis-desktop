/** Adapt one nested tool call to DSH 0.2.2+ batch tools.execute. */
export async function executeOneTool(tools, input) {
  const args = input.arguments;
  const batch = await tools.execute({
    calls: [{
      type: 'tool-call',
      id: input.callId,
      name: input.name,
      arguments: typeof args === 'string' ? args : JSON.stringify(args ?? {}),
    }],
    agent: input.agent,
    signal: input.signal,
    ...(input.toolSet ? { toolSet: input.toolSet } : {}),
    ...(input.log ? { log: input.log } : {}),
    ...(input.maxParallelToolCalls != null ? { maxParallelToolCalls: input.maxParallelToolCalls } : {}),
  });
  const result = batch.results?.[0]?.result;
  if (!result) throw new Error(`tools.execute returned no result for ${input.name}`);
  return {
    ...result,
    additionalContexts: [...(batch.additionalContexts ?? []), ...(result.additionalContexts ?? [])],
  };
}
