// Review this inventory when the kaiwu release adds or removes a package.
// Only product packages are selected or exposed by the default personal Profile.
export const PRODUCT_PACKAGES = Object.freeze([
  'workdsh-plugin-connectors',
  'workdsh-plugin-experts',
  'workdsh-plugin-library',
  'workdsh-plugin-projects',
  'workdsh-plugin-skills',
  'workdsh-plugin-workbenches',
])

// External enterprise packages: installed explicitly, never included in the base installer.
export const ENTERPRISE_PACKAGES = Object.freeze([
  'workdsh-provider-identity-enterprise',
  'workdsh-plugin-enterprise-collaboration',
  'workdsh-enterprise-connection',
])

/** Non-workdsh bundles activated for the default personal Profile. */
export const PERSONAL_DEFAULT_EXTRA_BUNDLES = Object.freeze([
  '@deepseek-ai/dsh-experimental-auto-review',
])

// Keep the already shipped community catalog integrations on the same Profile.
export const CATALOG_PACKAGES = Object.freeze({
  '@cocofhu/skillhub': '0.2.16',
  dshmarket: '1.66.8',
  // Praxis plugins that shipped preinstalled. Versions track DSH 0.2.1;
  // the 0.1.7 pins no longer resolve on this runtime.
  'dsh-ui-appearance': '0.1.23',
  'dsh-better-sidebar': '0.28.0',
  '@xmanrui/dsh-im': '5.4.0',
  'dsh-living-memory': '0.2.10',
  // Praxis: image transcription for text-only models (设置 → 视觉增强).
  'dsh-vision-plugin': '1.4.0',
  // Praxis default community plugins (personal base installer).
  'dsh-mineru': '0.1.15',
  // https://github.com/liustack/modsearch — free web search / fetch for DSH.
  '@liustack/modsearch': '5.10.10',
  'dsh-video-lens': '0.3.2',
  // Windows-oriented video studio; still ship so plugin inventory is complete.
  'dsh-video-studio': '0.4.3',
})

export const RELEASE_PACKAGES = Object.freeze([
  'workdsh-contracts',
  'workdsh-ui',
  'workdsh-provider-identity-local',
  'workdsh-provider-browser-session',
  'workdsh-plugin-audit',
  'workdsh-plugin-access',
  'workdsh-plugin-skills',
  'workdsh-plugin-experts',
  'workdsh-plugin-connectors',
  'workdsh-plugin-library',
  'workdsh-bundle',
  'workdsh-plugin-projects',
  'workdsh-plugin-workbenches',
])

export const PACKAGE_DIRECTORIES = Object.freeze({
  'workdsh-contracts': '../../packages/contracts',
  'workdsh-ui': '../../packages/ui',
  'workdsh-provider-identity-local': '../../packages/providers/identity-local',
  'workdsh-provider-browser-session': '../../packages/providers/browser-session',
  'workdsh-plugin-audit': '../../packages/plugins/audit',
  'workdsh-plugin-access': '../../packages/plugins/access',
  'workdsh-plugin-skills': '../../packages/plugins/skills',
  'workdsh-plugin-experts': '../../packages/plugins/experts',
  'workdsh-plugin-connectors': '../../packages/plugins/connectors',
  'workdsh-plugin-library': '../../packages/plugins/library',
  'workdsh-bundle': '../../packages/bundle',
  'workdsh-plugin-projects': '../../packages/plugins/projects',
  'workdsh-plugin-workbenches': '../../packages/plugins/workbenches',
  'workdsh-provider-identity-enterprise': '../../packages/providers/identity-enterprise',
  'workdsh-plugin-enterprise-collaboration': '../../packages/plugins/enterprise-collaboration',
})
