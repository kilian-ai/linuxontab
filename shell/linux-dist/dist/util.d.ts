export declare function assert(cond: unknown, message?: string): asserts cond;
export declare function unreachable(_: never, message?: string): never;
export declare function get_script_path(fn: () => void, import_meta: ImportMeta): URL;
export declare class EventEmitter<Events> {
    #private;
    on<K extends keyof Events>(event: K, handler: (data: Events[K]) => void): void;
    off<K extends keyof Events>(event: K, handler: (data: Events[K]) => void): void;
    protected emit<K extends keyof Events>(event: K, data: Events[K]): void;
}
