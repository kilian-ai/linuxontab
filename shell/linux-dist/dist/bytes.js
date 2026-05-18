import { assert } from "./util.js";
export function Struct(layout) {
    let size = 0;
    return class {
        #dv;
        constructor(view) {
            this.#dv = new DataView(view.buffer, view.byteOffset, view.byteLength);
        }
        static {
            for (const [key, type] of Object.entries(layout)) {
                const offset = size;
                Object.defineProperty(this.prototype, key, {
                    get() {
                        return type.get(this.#dv, offset);
                    },
                    set(value) {
                        type.set(this.#dv, offset, value);
                    },
                });
                size += type.size;
            }
        }
        static get(dv, offset) {
            if (offset !== 0)
                dv = new DataView(dv.buffer, dv.byteOffset + offset);
            return new this(dv);
        }
        static set(dv, offset, value) {
            if (offset !== 0)
                dv = new DataView(dv.buffer, dv.byteOffset + offset);
            Object.assign(new this(dv), value);
        }
        static size = size;
        toJSON() {
            const obj = {};
            for (const key in layout) {
                obj[key] = this[key];
            }
            return obj;
        }
    };
}
export function FixedArray(type, length) {
    assert(Number.isInteger(length) && length > 0);
    return {
        get(dv, offset) {
            const arr = Array(length);
            for (let i = 0; i < length; i++) {
                arr[i] = type.get(dv, offset + type.size * i);
            }
            return arr;
        },
        set(dv, offset, value) {
            for (let i = 0; i < length; i++) {
                type.set(dv, offset + type.size * i, value[i]);
            }
        },
        size: type.size * length,
    };
}
export const U8 = {
    get(dv, offset) {
        return dv.getUint8(offset);
    },
    set(dv, offset, value) {
        dv.setUint8(offset, value);
    },
    size: 1,
};
export const U16LE = {
    get(dv, offset) {
        return dv.getUint16(offset, true);
    },
    set(dv, offset, value) {
        dv.setUint16(offset, value, true);
    },
    size: 2,
};
export const U32LE = {
    get(dv, offset) {
        return dv.getUint32(offset, true);
    },
    set(dv, offset, value) {
        dv.setUint32(offset, value, true);
    },
    size: 4,
};
export const U64LE = {
    get(dv, offset) {
        return dv.getBigUint64(offset, true);
    },
    set(dv, offset, value) {
        dv.setBigUint64(offset, value, true);
    },
    size: 8,
};
export const U16BE = {
    get(dv, offset) {
        return dv.getUint16(offset, false);
    },
    set(dv, offset, value) {
        dv.setUint16(offset, value, false);
    },
    size: 2,
};
export const U32BE = {
    get(dv, offset) {
        return dv.getUint32(offset, false);
    },
    set(dv, offset, value) {
        dv.setUint32(offset, value, false);
    },
    size: 4,
};
export const U64BE = {
    get(dv, offset) {
        return dv.getBigUint64(offset, false);
    },
    set(dv, offset, value) {
        dv.setBigUint64(offset, value, false);
    },
    size: 8,
};
export class Bytes {
    #array;
    length = 0;
    get capacity() {
        return this.#array.length;
    }
    get array() {
        return this.#array.slice(0, this.length);
    }
    constructor(capacity = 32) {
        this.#array = new Uint8Array(capacity);
    }
    #ensure_capacity(capacity) {
        if (this.#array.length < capacity) {
            let length = this.#array.length;
            while (length < capacity)
                length *= 2;
            const next = new Uint8Array(length);
            next.set(this.#array);
            this.#array = next;
            this.#dv = undefined;
        }
    }
    bump(length) {
        const offset = this.length;
        this.#ensure_capacity(this.length + length);
        this.length += length;
        return offset;
    }
    append(bytes) {
        const offset = this.bump(bytes.length);
        this.#array.set(bytes, offset);
    }
    #dv;
    get dv() {
        return this.#dv ??= new DataView(this.#array.buffer);
    }
    alloc(type) {
        const offset = this.bump(type.size);
        const self = this;
        return {
            get value() {
                return type.get(self.dv, offset);
            },
            set value(value) {
                type.set(self.dv, offset, value);
            },
        };
    }
}
