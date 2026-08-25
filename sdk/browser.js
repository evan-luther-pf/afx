import {
  createFxAgent as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  supportsJspi,
  xtermAdapter,
} from "./afx-sdk.js";

export { encodeXtermKeyEvent, fxSdkApiVersion, supportsJspi, xtermAdapter };
export const libfxApiVersion = 2;

const defaultCoreWasm = new URL("./afx-core.wasm", import.meta.url).href;
const defaultTermWasm = new URL("./afx-term.wasm", import.meta.url).href;

export function createFxAgent(options = {}) {
  return createWasmAgent({ ...options, wasm: options.wasm ?? defaultCoreWasm });
}

export function createFxTerminal(options = {}) {
  return createWasmTerminal({ ...options, wasm: options.wasm ?? defaultTermWasm });
}
