/** Enterprise delivery prefers the bundled 企业连接 Profile; never copies account data. */
import {existsSync,mkdirSync,readFileSync,writeFileSync,readdirSync} from 'node:fs';
import {join} from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const execute=promisify(execFile);
export const enterprisePluginNames=['workdsh-provider-identity-enterprise','workdsh-plugin-enterprise-collaboration'] as const;
type ProfileManifest={dependencies?:Record<string,string>,optionalDependencies?:Record<string,string>};
function connectionSpec(manifest:ProfileManifest):string|undefined{
 return manifest.dependencies?.['workdsh-enterprise-connection']
  ?? manifest.optionalDependencies?.['workdsh-enterprise-connection'];
}
export function installedEnterprisePlugins(profile:string,version:string):string[]{
 if(!existsSync(join(profile,'package.json')))return [];
 const manifest=JSON.parse(readFileSync(join(profile,'package.json'),'utf8')) as ProfileManifest;
 const bundle=connectionSpec(manifest);
 const bundleRoot=join(profile,'node_modules','workdsh-enterprise-connection');
 if(bundle&&!existsSync(join(bundleRoot,'package.json')))throw Error('企业连接包尚未完成安装');
 const names:string[]=[];
 for(const name of enterprisePluginNames){
  if(!bundle&&![manifest.dependencies,manifest.optionalDependencies].some(section=>section?.[name]))continue;
  const path=join(bundle?bundleRoot:profile,'node_modules',name,'package.json');
  if(!existsSync(path))throw Error('企业插件尚未完成安装：'+name);
  const pkg=JSON.parse(readFileSync(path,'utf8'));
  if(pkg.name!==name||!pkg.exports?.['./desktop']||pkg.peerDependencies?.['@deepseek-ai/dsh']!==version)throw Error('企业插件与当前 DSH 不兼容：'+name);
  names.push(name);
 }
 return names;
}
/**
 * Prefer a ready personal Profile, then the immutable bundled installer Profile.
 * Incomplete personal materialization must not hide a complete bundled 企业连接.
 */
export function resolveEnterprisePluginSource(personalProfile:string,bundledProfile:string,version:string):string|undefined{
 for(const profile of [personalProfile,bundledProfile]){
  try{
   if(installedEnterprisePlugins(profile,version).includes(enterprisePluginNames[0]))return profile;
  }catch{
   // Try the next candidate; half-installed personal Homes are common before first plugin sync.
  }
 }
 return undefined;
}
export async function composeInstalledEnterprisePlugins(source:string,target:string,version:string,node:string,pnpm:string):Promise<string[]>{
 const names=installedEnterprisePlugins(source,version);
 if(!names.includes(enterprisePluginNames[0]))throw Error('安装包缺少可用的企业连接组件，请使用含企业连接的完整安装包');
 const manifestFile=join(target,'package.json');const manifest=JSON.parse(readFileSync(manifestFile,'utf8'));
 const archives=join(target,'enterprise-plugin-archives');mkdirSync(archives,{recursive:true,mode:0o700});
 manifest.dependencies??={};
 // Pack installed code through the bundled package manager; do not copy Profile files or credentials.
 for(const name of names){
  const sourceManifest=JSON.parse(readFileSync(join(source,'package.json'),'utf8')) as ProfileManifest;
  const directory=join(connectionSpec(sourceManifest)?join(source,'node_modules','workdsh-enterprise-connection'):source,'node_modules',name);
  const pkg=JSON.parse(readFileSync(join(directory,'package.json'),'utf8'));
  await execute(node,[pnpm,'pack','--pack-destination',archives],{cwd:directory,timeout:240000});
  const filename=name+'-'+pkg.version+'.tgz';
  if(!readdirSync(archives).includes(filename))throw Error('企业插件导出失败：'+name);
  manifest.dependencies[name]='file:./enterprise-plugin-archives/'+filename;
 }
 for(const name of enterprisePluginNames)if(!names.includes(name)){delete manifest.dependencies[name];delete manifest.optionalDependencies?.[name];}
 writeFileSync(manifestFile,JSON.stringify(manifest,null,2)+'\n',{mode:0o600});
 // Desktop has no TTY; do not abort when pnpm must rebuild node_modules.
 await execute(node,[pnpm,'--dir',target,'install','--prod','--force','--config.confirmModulesPurge=false'],{cwd:target,timeout:240000,env:{...process.env,CI:'true'}});
 return names;
}
