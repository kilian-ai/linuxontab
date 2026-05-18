export function assert(cond, message = "Assertation failed") {
    if (!cond)
        throw new Error(message);
}
export function unreachable(_, message = "Unreachable reached") {
    throw new Error(message);
}
export class EventEmitter {
    #subscribers = {};
    on(event, handler) {
        (this.#subscribers[event] ??= new Set()).add(handler);
    }
    off(event, handler) {
        this.#subscribers[event]?.delete(handler);
    }
    emit(event, data) {
        this.#subscribers[event]?.forEach((handler) => handler(data));
    }
}
