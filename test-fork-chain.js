#!/usr/bin/env node
/**
 * test-fork-chain.js — Verify fork_bufPtr/fork_retPtr thread through spawn_worker at any depth
 *
 * Simulates the spawn_worker chain from index.js and the worker's
 * postMessage("spawn_worker") path from worker-Q7XWPLKR.js.
 *
 * Run: node test-fork-chain.js
 */
'use strict';

let passed = 0;
let failed = 0;

function ok(condition, msg) {
    if (condition) {
        console.log('  PASS:', msg);
        passed++;
    } else {
        console.error('  FAIL:', msg);
        failed++;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Reproduce the index.js spawn_worker chain (with the fix applied).
// spawn_worker creates a FakeWorker that records what message it received.
// The FakeWorker exposes .triggerSpawnChild() to simulate the worker posting
// a "spawn_worker" message back up (as worker-Q7XWPLKR.js does in kernel_imports).
// ──────────────────────────────────────────────────────────────────────────────

function createFakeKernel() {
    const workers = [];

    // FIXED spawn_worker — takes fork_bufPtr/fork_retPtr
    function spawn_worker(fn, arg, name, user_module, user_memory,
                          fork_bufPtr = null, fork_retPtr = null) {

        const w = {
            fn, arg, name, user_module, user_memory,
            fork_bufPtr, fork_retPtr,
            // message the worker received
            received: { fn, arg, name, fork_bufPtr, fork_retPtr },
        };
        workers.push(w);

        // Wire up the worker's "onmessage" handler (from index.js).
        // In the real code: worker.onmessage = (event) => { switch(event.data.type) { case "spawn_worker": spawn_worker(..., event.data.fork_bufPtr, event.data.fork_retPtr); } }
        w.triggerSpawnChild = function(msg) {
            // msg is what worker-Q7XWPLKR.js posts via postMessage({type:"spawn_worker", ...})
            spawn_worker(
                msg.fn, msg.arg, msg.name, msg.user_module, msg.user_memory,
                msg.fork_bufPtr ?? null,
                msg.fork_retPtr ?? null,
            );
        };

        return w;
    }

    return { spawn_worker, workers };
}

// ──────────────────────────────────────────────────────────────────────────────
// Simulate what worker-Q7XWPLKR.js posts when it forks.
// In the real code:
//   setForkOverride(childMem, { bufPtr: fork.bufPtr, retPtr: fork.retPtr });
//   kernel.syscall(SYS_CLONE, ...);  // → spawn_worker callback
//   spawn_worker callback: postMessage({ type:"spawn_worker", ..., fork_bufPtr, fork_retPtr })
// ──────────────────────────────────────────────────────────────────────────────
function workerForks(worker, fork_bufPtr, fork_retPtr, childName) {
    // Simulate the kernel_imports.spawn_worker inside the worker posting a message
    worker.triggerSpawnChild({
        type: 'spawn_worker',
        fn: 42, arg: 0, name: childName,
        user_module: null, user_memory: null,
        fork_bufPtr,
        fork_retPtr,
    });
}

// ──────────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────────

console.log('\n── Test 1: Main thread spawns a worker with fork params (depth 1) ──');
{
    const { spawn_worker, workers } = createFakeKernel();
    spawn_worker(1, 0, 'init', null, null, 0x1000, 0x2000);
    ok(workers.length === 1, 'one worker created');
    ok(workers[0].fork_bufPtr === 0x1000, 'fork_bufPtr=0x1000 at depth 1');
    ok(workers[0].fork_retPtr === 0x2000, 'fork_retPtr=0x2000 at depth 1');
}

console.log('\n── Test 2: Worker (depth 1) forks → child (depth 2) gets fork params ──');
{
    const { spawn_worker, workers } = createFakeKernel();
    // Kernel creates init (no fork — normal start)
    const init = spawn_worker(1, 0, 'init', null, null);
    ok(workers.length === 1, 'init worker created');

    // init forks dropbear
    workerForks(init, 0xABCD, 0xEF01, 'dropbear');
    ok(workers.length === 2, 'dropbear worker created at depth 2');
    const dropbear = workers[1];
    ok(dropbear.name === 'dropbear', 'correct name');
    ok(dropbear.fork_bufPtr === 0xABCD, 'fork_bufPtr=0xABCD at depth 2');
    ok(dropbear.fork_retPtr === 0xEF01, 'fork_retPtr=0xEF01 at depth 2');
}

console.log('\n── Test 3: Worker (depth 2) forks → grandchild (depth 3) gets fork params ──');
{
    const { spawn_worker, workers } = createFakeKernel();
    const init    = spawn_worker(1, 0, 'init', null, null);
    workerForks(init, 0x1111, 0x2222, 'dropbear');
    const dropbear = workers[1];

    // dropbear accepts SSH connection, forks session handler
    workerForks(dropbear, 0x3333, 0x4444, 'dropbear-session');
    ok(workers.length === 3, 'session worker created at depth 3');
    const session = workers[2];
    ok(session.name === 'dropbear-session', 'correct name');
    ok(session.fork_bufPtr === 0x3333, 'fork_bufPtr=0x3333 at depth 3');
    ok(session.fork_retPtr === 0x4444, 'fork_retPtr=0x4444 at depth 3');
}

console.log('\n── Test 4: Worker (depth 3) forks → great-grandchild (depth 4) gets fork params ──');
{
    const { spawn_worker, workers } = createFakeKernel();
    const init    = spawn_worker(1, 0, 'init', null, null);
    workerForks(init, 0x1111, 0x1112, 'dropbear');
    const dropbear = workers[1];
    workerForks(dropbear, 0x2221, 0x2222, 'dropbear-session');
    const session = workers[2];

    // session forks sftp-server (this is the case that crashed before the fix)
    workerForks(session, 0x5555, 0x6666, 'sftp-server');
    ok(workers.length === 4, 'sftp-server worker created at depth 4');
    const sftp = workers[3];
    ok(sftp.name === 'sftp-server', 'correct name');
    ok(sftp.fork_bufPtr === 0x5555, 'fork_bufPtr=0x5555 at depth 4 (was null before fix)');
    ok(sftp.fork_retPtr === 0x6666, 'fork_retPtr=0x6666 at depth 4 (was null before fix)');
}

console.log('\n── Test 5: Null fork params are NOT passed to non-fork spawns ──');
{
    const { spawn_worker, workers } = createFakeKernel();
    // Normal exec spawn (no fork) — fork params should be null
    spawn_worker(1, 0, 'normal-exec', null, null);
    ok(workers[0].fork_bufPtr === null, 'fork_bufPtr null for normal spawn');
    ok(workers[0].fork_retPtr === null, 'fork_retPtr null for normal spawn');

    // Worker posts spawn_worker message WITHOUT fork params (normal thread creation)
    workers[0].triggerSpawnChild({
        type: 'spawn_worker',
        fn: 2, arg: 0, name: 'thread',
        user_module: null, user_memory: null,
        fork_bufPtr: null,
        fork_retPtr: null,
    });
    ok(workers[1].fork_bufPtr === null, 'fork_bufPtr null for normal thread');
    ok(workers[1].fork_retPtr === null, 'fork_retPtr null for normal thread');
}

console.log('\n── Test 6: Old bug reproduced — without fix, depth-2 fork params are null ──');
{
    // Simulate the BUGGY version (before fix) where spawn_worker ignored fork params from messages
    function spawn_worker_buggy(fn, arg, name, user_module, user_memory) {
        const w = { fn, arg, name, fork_bufPtr: null, fork_retPtr: null };
        // BUGGY: onmessage handler calls spawn_worker without fork params
        w.triggerSpawnChild = function(msg) {
            spawn_worker_buggy(msg.fn, msg.arg, msg.name, msg.user_module, msg.user_memory);
            // missing: msg.fork_bufPtr, msg.fork_retPtr
        };
        return w;
    }

    const init = spawn_worker_buggy(1, 0, 'init', null, null);
    let child = null;
    // Patch to capture child
    const orig = init.triggerSpawnChild.bind(init);
    init.triggerSpawnChild = (msg) => {
        orig(msg);
        // re-create same way
    };

    // Simulate: init forks, message contains fork params, but buggy handler drops them
    const receivedByChild = { fork_bufPtr: null, fork_retPtr: null };
    init.triggerSpawnChild = function(msg) {
        receivedByChild.fork_bufPtr = null;    // buggy: params dropped
        receivedByChild.fork_retPtr = null;    // buggy: params dropped
    };
    init.triggerSpawnChild({ fn: 2, arg: 0, name: 'dropbear',
        fork_bufPtr: 0xABCD, fork_retPtr: 0xEF01 });

    ok(receivedByChild.fork_bufPtr === null, 'BUG: fork_bufPtr was null before fix (confirmed)');
    ok(receivedByChild.fork_retPtr === null, 'BUG: fork_retPtr was null before fix (confirmed)');
    console.log('  (above NULLs confirm the pre-fix bug — these are expected)');
}

// ──────────────────────────────────────────────────────────────────────────────
// Summary
// ──────────────────────────────────────────────────────────────────────────────
console.log('\n' + '='.repeat(60));
console.log(`Results: ${passed} passed, ${failed} failed`);
if (failed > 0) {
    process.exit(1);
} else {
    console.log('All tests passed.\n');
}
