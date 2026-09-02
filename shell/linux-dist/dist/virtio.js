import { FixedArray, Struct, U16LE, U32LE, U64LE, U8, } from "./bytes.js";
import { assert } from "./util.js";
const TransportFeatures = {
    VERSION_1: 1n << 32n,
    RING_PACKED: 1n << 34n,
    INDIRECT_DESC: 1n << 28n,
};
const DescriptorFlags = {
    NEXT: 1 << 0,
    WRITE: 1 << 1,
    INDIRECT: 1 << 2,
    AVAIL: 1 << 7,
    USED: 1 << 15,
};
class VirtqDescriptor extends Struct({
    addr: U64LE,
    len: U32LE,
    id: U16LE,
    flags: U16LE,
}) {
}
class Chain {
    #mem;
    #queue;
    id;
    skip;
    desc;
    constructor(mem, queue, id, skip, desc) {
        this.#mem = mem;
        this.#queue = queue;
        this.id = id;
        this.skip = skip;
        this.desc = desc;
    }
    release(written) {
        const queue = this.#queue;
        const desc = queue.desc[queue.used_idx];
        assert(desc);
        const avail = (desc.flags & DescriptorFlags.AVAIL) !== 0;
        const used = (desc.flags & DescriptorFlags.USED) !== 0;
        if (avail === used || avail !== queue.wrap)
            throw new Error("ring full");
        let flags = 0;
        if (queue.wrap)
            flags |= DescriptorFlags.AVAIL | DescriptorFlags.USED;
        if (written > 0)
            flags |= DescriptorFlags.WRITE;
        desc.id = this.id;
        desc.len = written;
        desc.flags = flags;
        queue.used_idx += this.skip;
        if (queue.used_idx >= queue.size) {
            queue.used_idx -= queue.size;
            queue.wrap = !queue.wrap;
        }
    }
    *[Symbol.iterator]() {
        for (const desc of this.desc) {
            yield {
                array: new Uint8Array(this.#mem.buffer, Number(desc.addr), desc.len),
                writable: (desc.flags & DescriptorFlags.WRITE) !== 0,
            };
        }
    }
}
class Virtqueue {
    #mem;
    size;
    desc;
    wrap = true;
    used_idx = 0;
    avail_idx = 0;
    constructor(mem, size, desc_addr) {
        assert(size !== 0);
        assert(mem.byteOffset === 0);
        this.#mem = mem;
        this.size = size;
        this.desc = FixedArray(VirtqDescriptor, size).get(mem, desc_addr);
    }
    #pop() {
        let i = this.#advance();
        if (i === null)
            return null;
        const head = i;
        let desc = this.desc[i];
        assert(desc);
        const chain = new Chain(this.#mem, this, desc.id, 1, this.desc.slice(head, i + 1));
        if (desc.flags & DescriptorFlags.NEXT) {
            do {
                i = this.#advance();
                if (i === null)
                    throw new Error("no next descriptor is available");
                desc = this.desc[i];
                assert(desc);
            } while (desc.flags & DescriptorFlags.NEXT);
            chain.skip = i - head + 1;
            chain.desc = this.desc.slice(head, i + 1);
        }
        else if (desc.flags & DescriptorFlags.INDIRECT) {
            if (desc.len % VirtqDescriptor.size !== 0) {
                throw new Error("malformed indirect buffer");
            }
            chain.desc = FixedArray(VirtqDescriptor, desc.len / VirtqDescriptor.size)
                .get(this.#mem, Number(desc.addr));
        }
        return chain;
    }
    *[Symbol.iterator]() {
        let chain;
        while (chain = this.#pop())
            yield chain;
    }
    #advance() {
        const desc = this.desc[this.avail_idx];
        assert(desc);
        const avail = (desc.flags & DescriptorFlags.AVAIL) !== 0;
        const used = (desc.flags & DescriptorFlags.USED) !== 0;
        if (avail === used || avail !== this.wrap)
            return null;
        const index = this.avail_idx;
        this.avail_idx = (this.avail_idx + 1) % this.size;
        return index;
    }
}
export class VirtioDevice {
    features = TransportFeatures.VERSION_1 | TransportFeatures.RING_PACKED |
        TransportFeatures.INDIRECT_DESC;
    trigger_interrupt = (kind) => {
        // this function is overwritten on device setup
        void kind;
        throw new Error("trigger_interrupt called before setup");
    };
    vqs = [];
    enable(vq, queue) {
        this.vqs[vq] = queue;
    }
    disable(vq) {
        const queue = this.vqs[vq];
        assert(queue);
    }
    setup_complete() { }
}
class EmptyStruct extends Struct({}) {
}
const BlockDeviceFeatures = {
    RO: 1n << 5n,
    FLUSH: 1n << 9n,
};
class BlockDeviceConfig extends Struct({
    capacity: U64LE,
}) {
}
class BlockDeviceRequest extends Struct({
    type: U32LE,
    reserved: U32LE,
    sector: U64LE,
}) {
}
const BlockDeviceRequestType = {
    IN: 0,
    OUT: 1,
    FLUSH: 4,
    GET_ID: 8,
};
const BlockDeviceStatus = {
    OK: 0,
    IOERR: 1,
    UNSUPP: 2,
};
export class BlockDevice extends VirtioDevice {
    ID = 2;
    config_bytes = new Uint8Array(BlockDeviceConfig.size);
    config = new BlockDeviceConfig(this.config_bytes);
    #storage;
    constructor(storage) {
        super();
        this.#storage = storage;
        if (storage.flush)
            this.features |= BlockDeviceFeatures.FLUSH;
        if (!storage.write)
            this.features |= BlockDeviceFeatures.RO;
        this.config.capacity = BigInt(storage.capacity / 512);
    }
    async notify(vq) {
        assert(vq === 0);
        const queue = this.vqs[vq];
        assert(queue);
        for (const chain of queue) {
            const descs = [...chain];
            const header = descs[0];
            const status = descs[descs.length - 1];
            const data = descs.slice(1, -1);
            assert(header && !header.writable, "header must be readonly");
            assert(header.array.byteLength === BlockDeviceRequest.size, `header size is ${header.array.byteLength}`);
            assert(status && status.writable, "status must be writable");
            assert(status.array.byteLength === 1, `status size is ${status.array.byteLength}`);
            const status_desc = status;
            const request = new BlockDeviceRequest(header.array);
            function set_status(value) {
                status_desc.array[0] = value;
            }
            let n = 0;
            let offset = Number(request.sector) * 512;
            switch (request.type) {
                case BlockDeviceRequestType.IN: {
                    for (const desc of data) {
                        assert(desc.writable, "data must be writable when IN");
                        const arr = await this.#storage.read(offset, desc.array.byteLength);
                        desc.array.set(arr);
                        n += arr.byteLength;
                        offset += arr.byteLength;
                    }
                    set_status(BlockDeviceStatus.OK);
                    break;
                }
                case BlockDeviceRequestType.OUT: {
                    if (!this.#storage.write) {
                        set_status(BlockDeviceStatus.UNSUPP);
                        break;
                    }
                    let ok = true;
                    for (const desc of data) {
                        assert(!desc.writable, "data must be readonly when OUT");
                        const written = await this.#storage.write(offset, desc.array);
                        if (written !== desc.array.byteLength) {
                            ok = false;
                            break;
                        }
                        n += written;
                        offset += written;
                    }
                    set_status(ok ? BlockDeviceStatus.OK : BlockDeviceStatus.IOERR);
                    break;
                }
                case BlockDeviceRequestType.FLUSH: {
                    if (!this.#storage.flush) {
                        set_status(BlockDeviceStatus.UNSUPP);
                        break;
                    }
                    await this.#storage.flush();
                    set_status(BlockDeviceStatus.OK);
                    break;
                }
                case BlockDeviceRequestType.GET_ID: {
                    console.log("GET_ID");
                    set_status(BlockDeviceStatus.OK);
                    break;
                }
                default:
                    console.error("unknown request type", request.type);
                    set_status(BlockDeviceStatus.UNSUPP);
            }
            chain.release(n);
        }
        this.trigger_interrupt("vring");
    }
}
export class ConsoleDevice extends VirtioDevice {
    ID = 3;
    config_bytes = new Uint8Array(0);
    config = new EmptyStruct(this.config_bytes);
    #input;
    #output;
    constructor(input, output) {
        super();
        this.#input = input;
        this.#output = output.getWriter();
    }
    #pendingInput = [];
    #warnedInputBacklog = false;
    #enqueueInput(chunk) {
        if (chunk.length === 0)
            return;
        this.#pendingInput.push(chunk.slice());
    }
    #flushPending(queue) {
        let wrote = false;
        while (this.#pendingInput.length > 0) {
            const chain = queue[Symbol.iterator]().next().value;
            if (!chain) {
                if (!this.#warnedInputBacklog) {
                    console.warn("no more descriptors, queueing console input");
                    this.#warnedInputBacklog = true;
                }
                break;
            }
            const [desc, trailing] = chain;
            assert(desc && desc.writable, "receiver must be writable");
            assert(!trailing, "too many descriptors");
            const chunk = this.#pendingInput[0];
            const n = Math.min(chunk.length, desc.array.byteLength);
            desc.array.set(chunk.subarray(0, n));
            if (n === chunk.length)
                this.#pendingInput.shift();
            else
                this.#pendingInput[0] = chunk.subarray(n);
            chain.release(n);
            wrote = true;
        }
        if (this.#pendingInput.length === 0)
            this.#warnedInputBacklog = false;
        if (wrote)
            this.trigger_interrupt("vring");
    }
    #writing = null;
    async #writer(queue) {
        const reader = this.#input.getReader();
        for (;;) {
            const { value, done } = await reader.read();
            if (done)
                break;
            if (value)
                this.#enqueueInput(value);
            this.#flushPending(queue);
        }
    }
    async notify(vq) {
        const queue = this.vqs[vq];
        assert(queue);
        switch (vq) {
            case 0:
                this.#writing ??= this.#writer(queue);
                this.#flushPending(queue);
                break;
            case 1:
                for (const chain of queue) {
                    let n = 0;
                    for (const { array, writable } of chain) {
                        assert(!writable, "transmitter must be readable");
                        await this.#output.write(array);
                        n += array.byteLength;
                    }
                    chain.release(n);
                }
                break;
            default:
                console.error("ConsoleDevice: unknown vq", vq);
        }
    }
}
const NetworkDeviceFeatures = {
    MAC: 1n << 5n,
};
class NetworkDeviceConfig extends Struct({
    mac0: U8, mac1: U8, mac2: U8, mac3: U8, mac4: U8, mac5: U8,
    status: U16LE,
}) {
}
export class NetworkDevice extends VirtioDevice {
    ID = 1;
    config_bytes = new Uint8Array(NetworkDeviceConfig.size);
    config = new NetworkDeviceConfig(this.config_bytes);
    #mac;
    #backend;
    #rx_queue_ready = false;
    constructor(mac, backend) {
        super();
        assert(mac.byteLength >= 6, "MAC must be 6 bytes");
        this.#mac = mac;
        this.#backend = backend;
        this.features |= NetworkDeviceFeatures.MAC;
        // Store MAC in config_bytes so kernel reads it from the config space.
        for (let i = 0; i < 6; i++)
            this.config_bytes[i] = mac[i];
        // Bind the backend's receive callback to our inject method.
        backend.receive = (frame) => this.#injectRx(frame);
        // Missed-doorbell insurance. The guest driver can add TX frames (or
        // RX refill buffers) to a ring WITHOUT ringing the doorbell again —
        // virtio notification suppression assumes the device keeps polling
        // while busy. This device only reads the rings inside notify(), so a
        // suppressed doorbell left frames sitting forever: observed as a hard
        // TCP jam where the guest polls write() against a full sndbuf and no
        // frame ever hits the wire in either direction. Sweep both rings on
        // a short timer; an empty sweep is nearly free.
        setInterval(() => {
            this.#txSweep(false);
            const rq = this.vqs[0];
            if (rq && this.#rx_queue_ready)
                this.#drainPending(rq);
        }, 50);
    }
    // Drain the transmit ring. force=true preserves notify()'s original
    // behaviour of always raising the completion interrupt.
    #txSweep(force) {
        const queue = this.vqs[1];
        if (!queue)
            return;
        let sent = 0;
        for (const chain of queue) {
            let totalLen = 0;
            const parts = [];
            for (const { array, writable } of chain) {
                assert(!writable, "TX descriptor must be readable");
                parts.push(array.slice(0)); // copy since SharedArrayBuffer
                totalLen += array.byteLength;
            }
            // Strip the 12-byte virtio_net_hdr_mrg_rxbuf before handing to backend.
            const HDR = 12;
            if (totalLen > HDR) {
                const full = new Uint8Array(totalLen);
                let off = 0;
                for (const p of parts) {
                    full.set(p, off);
                    off += p.byteLength;
                }
                this.#backend.send(full.subarray(HDR));
            }
            chain.release(totalLen);
            sent++;
        }
        if (sent || force)
            this.trigger_interrupt("vring");
    }
    // Queue of frames waiting for the guest to provide RX descriptors.
    #rxPending = [];
    // Re-kick state: interrupts written while the guest is busy coalesce into
    // one IRQ (trigger_interrupt just sets a flag), and the guest ISR does not
    // reliably drain every used entry per IRQ. Frames then sit in the ring
    // until the NEXT incoming frame re-kicks — which made bulk downloads run
    // at one segment per sender-RTO (~1 KB/s). Until the guest refills RX
    // buffers (notify(0), i.e. it visibly consumed something), keep re-raising
    // the vring interrupt on a short timer.
    #rekickTimer = null;
    #rekickStep = 0;
    #unconsumed = 0;
    // Bounded + decaying: a fixed unthrottled interval turned into an IRQ storm
    // that froze the guest outright. A few spaced kicks per frame batch is
    // enough to drain a partially-processed ring without starving the guest.
    static #REKICK_DELAYS = [30, 60, 120, 250, 500, 1000];
    // LOT 2026-09-02: after the decaying schedule, keep kicking at a gentle
    // steady cadence instead of giving up. Giving up after ~2 s left every
    // guest->page transfer above ~650 KB stalled for good: the guest misses an
    // RX interrupt mid-stream (ACKs sit in the ring unprocessed), stops
    // sending, and nothing new arrives to re-arm the kick. Measured: manual
    // 250 ms kicks revive a stalled 650 KB transfer. The loop still ends the
    // moment the guest refills RX (notify(0) zeroes #unconsumed), and is
    // capped so a truly dead guest cannot be kicked forever.
    static #REKICK_STEADY_MS = 250;
    static #REKICK_MAX_STEPS = 240;   // 6 decaying + ~60 s of steady kicks
    #armRekick() {
        if (this.#rekickTimer)
            return;
        const step = () => {
            this.#rekickTimer = null;
            if (this.#unconsumed <= 0 && this.#rxPending.length === 0)
                return;
            if (this.#rekickStep >= NetworkDevice.#REKICK_MAX_STEPS)
                return; // give up; next injected frame re-arms
            try { this.trigger_interrupt("vring"); } catch (e) { /* not set up yet */ }
            const i = this.#rekickStep++;
            const delay = i < NetworkDevice.#REKICK_DELAYS.length ? NetworkDevice.#REKICK_DELAYS[i] : NetworkDevice.#REKICK_STEADY_MS;
            this.#rekickTimer = setTimeout(step, delay);
        };
        this.#rekickTimer = setTimeout(step, NetworkDevice.#REKICK_DELAYS[0]);
    }
    // Inject an Ethernet frame into the guest's receive queue.
    #injectRx(frame) {
        const queue = this.vqs[0]; // receiveq
        if (!queue || !this.#rx_queue_ready) {
            if (globalThis.__netdebug) console.log('[VIRTIO RX] pending (queue='+(!!queue)+' ready='+this.#rx_queue_ready+')');
            this.#rxPending.push(frame);
            return;
        }
        this.#drainPending(queue);
        const ok = this.#writeRxFrame(queue, frame);
        // Per-packet logging is gated: at bulk-transfer rates (thousands of
        // frames/sec) unconditional console.log stalls the main thread long
        // enough that WS dispatch stops and the WISP watchdog kills a healthy
        // link. Enable with ?netdebug.
        if (globalThis.__netdebug) console.log('[VIRTIO RX] writeRxFrame len='+frame.byteLength+' ok='+ok+' pending='+this.#rxPending.length);
        if (!ok)
            this.#rxPending.push(frame);  // no RX descriptors available — queue it
        else
            this.#unconsumed += 1;
        this.#rekickStep = 0;   // fresh frame — restart the decay schedule
        this.#armRekick();
    }
    #drainPending(queue) {
        while (this.#rxPending.length > 0) {
            const f = this.#rxPending[0];
            if (!this.#writeRxFrame(queue, f))
                break;
            this.#rxPending.shift();
            this.#unconsumed += 1;
        }
        if (this.#unconsumed > 0)
            this.#armRekick();
    }
    // Write a single frame into the RX virtqueue. Returns false if no descriptors available.
    #writeRxFrame(queue, frame) {
        // virtio_net_hdr_mrg_rxbuf = 12 bytes: 10-byte virtio_net_hdr + u16 num_buffers.
        // The @tombl/linux kernel uses vi->hdr_len=12 for both TX and RX, so we must
        // write a 12-byte header. num_buffers=1 (we always use a single RX buffer).
        const HDR = 12;
        const total = HDR + frame.byteLength;
        for (const chain of queue) {
            let offset = 0;
            for (const { array, writable } of chain) {
                if (!writable)
                    continue;
                const slice = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
                if (offset < HDR) {
                    // write 12-byte header: 10 zeros (no offloading) + num_buffers=1 (LE16)
                    const hdrBytes = Math.min(HDR - offset, slice.byteLength);
                    // bytes 10-11 = num_buffers = 1 (little-endian)
                    if (offset <= 10 && offset + hdrBytes > 10) slice[10 - offset] = 1;
                    if (offset <= 11 && offset + hdrBytes > 11) slice[11 - offset] = 0;
                    offset += hdrBytes;
                    const remaining = slice.byteLength - hdrBytes;
                    if (remaining > 0 && frame.byteLength > 0) {
                        const frameBytes = Math.min(frame.byteLength, remaining);
                        slice.set(frame.subarray(0, frameBytes), hdrBytes);
                    }
                }
                else {
                    const frameOff = offset - HDR;
                    const n = Math.min(frame.byteLength - frameOff, slice.byteLength);
                    slice.set(frame.subarray(frameOff, frameOff + n));
                }
                offset += slice.byteLength;
            }
            chain.release(total);
            this.trigger_interrupt("vring");
            return true;
        }
        return false;
    }
    notify(vq) {
        const queue = this.vqs[vq];
        assert(queue);
        switch (vq) {
            case 0: // receiveq — guest is providing RX buffers
                this.#rx_queue_ready = true;
                // Refill = the guest consumed frames; stop re-kicking for them.
                this.#unconsumed = 0;
                this.#rekickStep = 0;
                this.#drainPending(queue);
                break;
            case 1: { // transmitq — guest is sending frames
                this.#txSweep(true);
                break;
            }
            default:
                console.error("NetworkDevice: unknown vq", vq);
        }
    }
}
export class EntropyDevice extends VirtioDevice {
    ID = 4;
    config_bytes = new Uint8Array(0);
    config = new EmptyStruct(this.config_bytes);
    notify(vq) {
        assert(vq === 0);
        const queue = this.vqs[vq];
        assert(queue);
        for (const chain of queue) {
            let n = 0;
            for (const { array, writable } of chain) {
                assert(writable);
                // can't use crypto.getRandomValues on a SharedArrayBuffer
                const arr = new Uint8Array(array.length);
                crypto.getRandomValues(arr);
                array.set(arr);
                n += array.byteLength;
            }
            chain.release(n);
        }
        this.trigger_interrupt("vring");
    }
}
export function virtio_imports({ memory, devices, trigger_irq_for_cpu, }) {
    const dv = new DataView(memory.buffer);
    return {
        set_features(dev, features) {
            const device = devices[dev];
            assert(device);
            assert(device.features === features, "the kernel should accept every feature we offer, and no more");
        },
        enable_vring(dev, vq, size, desc_addr) {
            const device = devices[dev];
            assert(device);
            device.enable(vq, new Virtqueue(dv, size, desc_addr));
        },
        disable_vring(dev, vq) {
            const device = devices[dev];
            assert(device);
            device.disable(vq);
        },
        setup(dev, irq, is_config_addr, is_vring_addr, config_addr, config_len) {
            const device = devices[dev];
            assert(device);
            const config_type = device.config.constructor;
            assert(config_len >= config_type.size, "config space too small");
            const new_config_bytes = new Uint8Array(dv.buffer, config_addr, config_len);
            new_config_bytes.set(device.config_bytes);
            device.config_bytes = new_config_bytes;
            device.config = config_type.get(dv, config_addr);
            device.trigger_interrupt = (kind) => {
                U8.set(dv, is_config_addr, kind === "config" ? 1 : 0);
                U8.set(dv, is_vring_addr, kind === "vring" ? 1 : 0);
                trigger_irq_for_cpu(0, irq); // TODO: balance?
            };
            device.setup_complete();
        },
        notify(dev, vq) {
            const device = devices[dev];
            assert(device);
            device.notify(vq);
        },
    };
}
