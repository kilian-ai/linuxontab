const cp=require('child_process');
console.log('start');
cp.exec('ls /opt/x86 | wc -l', (e, out, err) => { console.log('cb', e ? 'ERR ' + e.message : 'ok', JSON.stringify(out), JSON.stringify(err)); });
setTimeout(() => console.log('timer still alive'), 3000);
process.on('exit', c => console.log('exit', c));
