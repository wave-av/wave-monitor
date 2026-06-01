/**
 * Minimal AudioWorkletGlobalScope typings. The DOM lib doesn't include them
 * because they only exist inside an AudioWorkletGlobalScope (worker-like).
 * Only the symbols our processor uses are declared.
 */

declare class AudioWorkletProcessor {
  readonly port: MessagePort;
  constructor();
  process(
    inputs: Float32Array[][],
    outputs: Float32Array[][],
    parameters: Record<string, Float32Array>,
  ): boolean;
}

declare function registerProcessor(
  name: string,
  ctor: new () => AudioWorkletProcessor,
): void;
