// SPDX-License-Identifier: MIT

interface EventEndpoint {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  addEventListener(type: "message", listener: (event: MessageEvent) => void): void;
  addEventListener(type: "messageerror", listener: (event: MessageEvent) => void): void;
  addEventListener(type: "error", listener: (event: ErrorEvent) => void): void;
  removeEventListener(type: "message", listener: (event: MessageEvent) => void): void;
  removeEventListener(type: "messageerror", listener: (event: MessageEvent) => void): void;
  removeEventListener(type: "error", listener: (event: ErrorEvent) => void): void;
  start?(): void;
}

export interface EmitterEndpoint {
  postMessage(message: unknown): void;
  on(type: "message", listener: (message: unknown) => void): void;
  on(type: "messageerror", listener: (error: Error) => void): void;
  on(type: "error", listener: (error: Error) => void): void;
  off(type: "message", listener: (message: unknown) => void): void;
  off(type: "messageerror", listener: (error: Error) => void): void;
  off(type: "error", listener: (error: Error) => void): void;
  start?(): void;
}

/** A browser Worker, MessagePort, or Node worker used for bidirectional messages. */
export type Endpoint = EventEndpoint | EmitterEndpoint;

/** @internal */
export interface EndpointHandlers {
  message(message: unknown): void;
  error?(error: Error): void;
}

const as_error = (value: unknown, fallback: string) =>
  value instanceof Error ? value : new Error(fallback);

/** @internal */
export function listen_endpoint(endpoint: Endpoint, handlers: EndpointHandlers) {
  if ("addEventListener" in endpoint) {
    const on_message = (event: MessageEvent) => handlers.message(event.data);
    const on_message_error = (_event: MessageEvent) =>
      handlers.error?.(new Error("could not deserialize endpoint message"));
    const on_error = (event: ErrorEvent) => {
      event.preventDefault();
      handlers.error?.(as_error(event.error, event.message || "worker failed"));
    };
    endpoint.addEventListener("message", on_message);
    if (handlers.error) {
      endpoint.addEventListener("messageerror", on_message_error);
      endpoint.addEventListener("error", on_error);
    }
    return () => {
      endpoint.removeEventListener("message", on_message);
      if (handlers.error) {
        endpoint.removeEventListener("messageerror", on_message_error);
        endpoint.removeEventListener("error", on_error);
      }
    };
  }

  const on_message = (message: unknown) => handlers.message(message);
  const on_message_error = (error: Error) =>
    handlers.error?.(as_error(error, "could not deserialize endpoint message"));
  const on_error = (error: Error) => handlers.error?.(as_error(error, "worker failed"));
  endpoint.on("message", on_message);
  if (handlers.error) {
    endpoint.on("messageerror", on_message_error);
    endpoint.on("error", on_error);
  }
  return () => {
    endpoint.off("message", on_message);
    if (handlers.error) {
      endpoint.off("messageerror", on_message_error);
      endpoint.off("error", on_error);
    }
  };
}

/** @internal */
export function post_endpoint(endpoint: Endpoint, message: unknown, transfer?: Transferable[]) {
  endpoint.postMessage(message, transfer);
}
