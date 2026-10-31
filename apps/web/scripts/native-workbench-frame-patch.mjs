// Compatibility entry for local Web preview; Desktop consumes the same locked adapter.
import {fileURLToPath} from 'node:url';
import {
  ensureNativeWorkbenchFrame,
  recomputeNativeWorkbenchFrameSpec,
} from '../../../scripts/native-workbench-frame-patch.mjs';
export {
  patchNativeWorkbenchFrame,
  recoverOriginalWorkbenchFrameSource,
  ensureNativeWorkbenchFrame,
  verifyNativeWorkbenchFrame,
  recomputeNativeWorkbenchFrameSpec,
} from '../../../scripts/native-workbench-frame-patch.mjs';
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
