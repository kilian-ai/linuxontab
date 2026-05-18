export interface Type<T> {
    get(dv: DataView, offset: number): T;
    set(dv: DataView, offset: number, value: T): void;
    size: number;
}
export type Unwrap<T> = T extends Type<infer U> ? U : never;
export declare function Struct<T extends object>(layout: {
    [K in keyof T]: Type<T[K]>;
}): {
    new (view: ArrayBufferView): T;
} & Type<T>;
export declare function FixedArray<T>(type: Type<T>, length: number): Type<T[]>;
export declare const U8: Type<number>;
export declare const U16LE: Type<number>;
export declare const U32LE: Type<number>;
export declare const U64LE: Type<bigint>;
export declare const U16BE: Type<number>;
export declare const U32BE: Type<number>;
export declare const U64BE: Type<bigint>;
export interface Allocated<T> {
    value: T;
}
export declare class Bytes {
    #private;
    length: number;
    get capacity(): number;
    get array(): Uint8Array;
    constructor(capacity?: number);
    bump(length: number): number;
    append(bytes: Uint8Array): void;
    get dv(): DataView;
    alloc<T>(type: Type<T>): Allocated<T>;
}
