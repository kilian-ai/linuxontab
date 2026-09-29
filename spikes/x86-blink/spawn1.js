const cp=require('child_process'); console.log('before'); console.log(cp.execSync('echo hi-from-child').toString().trim()); console.log('after');
