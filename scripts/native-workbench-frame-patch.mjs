import {readFile,writeFile,rename,rm,stat} from 'node:fs/promises';
import {createHash,randomUUID} from 'node:crypto';
import {createRequire} from 'node:module';
import {dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const specUrl=new URL('./native-workbench-frame-patch.json',import.meta.url);
const specPath=fileURLToPath(specUrl);
let spec=JSON.parse(await readFile(specUrl,'utf8'));
const hash=value=>createHash('sha256').update(value).digest('hex');
const reloadSpec=async()=>{spec=JSON.parse(await readFile(specUrl,'utf8'));return spec;};

function applyReplacements(source,replacements){
  let output=source;
  for(const [before,after] of replacements){
    if(output.split(before).length!==2)throw Error('Native frame patch anchor mismatch');
    output=output.replace(before,after);
  }
  return output;
}

function reverseReplacements(source,replacements){
  let output=source;
  for(const [before,after] of [...replacements].reverse()){
    if(output.split(after).length!==2)throw Error('Native frame patch reverse anchor mismatch');
    output=output.replace(after,before);
  }
  return output;
}

function uniqueAnchors(source,snippets){
  return snippets.every(snippet=>source.split(snippet).length===2);
}

/** Recover original conversation client bytes for recompute. Fail closed on ambiguity. */
export function recoverOriginalWorkbenchFrameSource(source,{replacements,originalSha256,patchedSha256}={...spec}){
  const digest=hash(source);
  if(digest===originalSha256)return source;
  if(digest===patchedSha256){
    const original=reverseReplacements(source,replacements);
    if(hash(original)!==originalSha256)throw Error('Native frame patch reverse digest mismatch');
    return original;
  }
  const befores=replacements.map(([before])=>before);
  const afters=replacements.map(([,after])=>after);
  if(uniqueAnchors(source,befores))return source;
  if(uniqueAnchors(source,afters))return reverseReplacements(source,replacements);
  throw Error('Native workbench frame: unsupported runtime bytes; refusing to recompute.');
}

export function patchNativeWorkbenchFrame(source){
  const digest=hash(source);if(digest===spec.patchedSha256)return source;
  if(digest!==spec.originalSha256)throw Error('Native workbench frame: unsupported runtime bytes; refusing to patch.');
  const output=applyReplacements(source,spec.replacements);
  if(hash(output)!==spec.patchedSha256)throw Error('Native frame patch result mismatch');return output;
}

// Replace this installation's directory entry, never mutate a pnpm hardlink
// in place (which could otherwise change a different Profile or the store).
async function replaceRuntimeFile(target,expected,next){
  const temporary=`${target}.workdsh-frame-${randomUUID()}`;
  const mode=(await stat(target)).mode&0o777;
  try{
    await writeFile(temporary,next,{flag:'wx',mode});
    if(hash(await readFile(target,'utf8'))!==hash(expected))throw Error('Native frame target changed during update');
    await rename(temporary,target);
  }finally{await rm(temporary,{force:true});}
}

async function resolveConversationClient(profile){
  const require=createRequire(join(profile,'package.json'));
  const path=require.resolve(`${spec.package}/package.json`);
  const manifest=JSON.parse(await readFile(path,'utf8'));
  const target=join(dirname(path),spec.file);
  return {manifest,target,source:await readFile(target,'utf8')};
}

export async function ensureNativeWorkbenchFrame(profile,{rollback=false}={}){
  const {manifest,target,source}=await resolveConversationClient(profile);
  if(manifest.version!==spec.version)throw Error('Native workbench frame: runtime version mismatch');
  if(rollback){
    if(hash(source)===spec.originalSha256)return;
    if(hash(source)!==spec.patchedSha256)throw Error('Cannot roll back unknown runtime');
    const original=reverseReplacements(source,spec.replacements);
    if(hash(original)!==spec.originalSha256)throw Error('Rollback mismatch');
    await replaceRuntimeFile(target,source,original);return;
  }
  const patched=patchNativeWorkbenchFrame(source);
  if(patched!==source)await replaceRuntimeFile(target,source,patched);
}

/** Read the installed artifact, rather than trusting a preparation receipt. */
export async function verifyNativeWorkbenchFrame(profile){
  const {manifest,target}=await resolveConversationClient(profile);
  if(manifest.version!==spec.version)throw Error('Native workbench frame: runtime version mismatch');
  const digest=hash(await readFile(target,'utf8'));
  if(digest!==spec.patchedSha256)throw Error(digest===spec.originalSha256
    ?'Native workbench frame: authorized adapter is missing from the packaged runtime'
    :'Native workbench frame: unsupported packaged runtime bytes');
  return {package:spec.package,version:spec.version,file:spec.file,sha256:digest};
}

/**
 * Rebuild locked digests from an installed Profile's conversation client.
 * Does not change prepare/ensure fail-closed behavior; callers must review and commit JSON.
 */
export async function recomputeNativeWorkbenchFrameSpec(profile,{write=true}={}){
  const require=createRequire(join(profile,'package.json'));
  const path=require.resolve(`${spec.package}/package.json`);
  const manifest=JSON.parse(await readFile(path,'utf8'));
  if(typeof manifest.version!=='string'||!manifest.version)throw Error('Native workbench frame: conversation package version missing');
  const target=join(dirname(path),spec.file);
  const source=await readFile(target,'utf8');
  const original=recoverOriginalWorkbenchFrameSource(source,{
    replacements:spec.replacements,
    originalSha256:spec.originalSha256,
    patchedSha256:spec.patchedSha256,
  });
  const patched=applyReplacements(original,spec.replacements);
  const next={
    package:spec.package,
    version:manifest.version,
    file:spec.file,
    originalSha256:hash(original),
    patchedSha256:hash(patched),
    replacements:spec.replacements,
  };
  if(write){
    const body=JSON.stringify(next,null,2)+'\n';
    const temporary=`${specPath}.workdsh-frame-${randomUUID()}`;
    try{
      await writeFile(temporary,body,{flag:'wx',mode:0o644});
      await rename(temporary,specPath);
    }finally{await rm(temporary,{force:true});}
    await reloadSpec();
  }
  return next;
}

if(process.argv[1]===fileURLToPath(import.meta.url)){
  const profile=process.argv.find((arg,index)=>index>=2&&!arg.startsWith('--'));
  if(!profile)throw Error('Profile path required');
  if(process.argv.includes('--recompute')){
    const next=await recomputeNativeWorkbenchFrameSpec(profile);
    process.stdout.write(JSON.stringify(next,null,2)+'\n');
  }else{
    await ensureNativeWorkbenchFrame(profile,{rollback:process.argv.includes('--rollback')});
  }
}
