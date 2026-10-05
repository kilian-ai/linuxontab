// Preloaded via NODE_OPTIONS (x86-env): V8 interpreter + Sparkplug only.
// Maglev/TurboFan don't pay off under Blink; NODE_OPTIONS rejects the flags.
const v8 = require('v8');
v8.setFlagsFromString('--no-maglev');
v8.setFlagsFromString('--no-turbofan');
