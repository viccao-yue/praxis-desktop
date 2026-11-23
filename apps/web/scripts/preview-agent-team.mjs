/** Keep the preview's Agent Team loader ids owned by one bundle. */
export function withoutRedundantAgentTeamProfile(manifest) {
  const bundles = manifest.dsh?.profile?.bundles;
  if (!Array.isArray(bundles) || !bundles.includes('workdsh-plugin-experts')) return undefined;
  // Official 0.2.2-rc.5 no longer ships a separate agent-team profile package.
  // Still strip the retired experimental profile id if an older template includes it.
  const filtered = bundles.filter(bundle => bundle !== '@deepseek-ai/dsh-experimental-agent-team-profile');
  if (filtered.length === bundles.length) return undefined;
  return { ...manifest, dsh: { ...manifest.dsh, profile: { ...manifest.dsh.profile, bundles: filtered } } };
}
