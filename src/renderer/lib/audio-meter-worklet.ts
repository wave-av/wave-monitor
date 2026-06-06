/**
 * AudioWorkletProcessor — computes per-channel peak + RMS at the worklet's
 * native callback cadence (every 128 samples = ~2.7ms @ 48kHz). We batch
 * those into ~50ms windows (every 20Hz) before posting to the main thread
 * to avoid drowning the renderer event loop in postMessage traffic.
 *
 * Output: { peak: [L, R], rms: [L, R] } in dBFS, clamped to [-100, 0].
 * Mono streams duplicate L into R.
 *
 * This file is loaded into an AudioWorkletGlobalScope, NOT the main renderer
 * scope. Anything DOM/React adjacent must not be referenced here.
 */

// eslint-disable-next-line @typescript-eslint/triple-slash-reference -- AudioWorkletGlobalScope does not support `import`; triple-slash is required here
/// <reference path="../audio-worklet-types.d.ts" />

const WINDOW_FRAMES = 2400; // ~50ms at 48kHz
const MIN_DBFS = -100;

interface ProcessorContext {
  peakL: number;
  peakR: number;
  sumSquaredL: number;
  sumSquaredR: number;
  frameCount: number;
}

function freshContext(): ProcessorContext {
  return {
    peakL: 0,
    peakR: 0,
    sumSquaredL: 0,
    sumSquaredR: 0,
    frameCount: 0,
  };
}

function toDbfs(linear: number): number {
  if (linear <= 0) return MIN_DBFS;
  const db = 20 * Math.log10(linear);
  return Math.max(MIN_DBFS, Math.min(0, db));
}

class WaveMeterProcessor extends AudioWorkletProcessor {
  private ctx: ProcessorContext = freshContext();

  override process(inputs: Float32Array[][]): boolean {
    const input = inputs[0];
    if (!input || input.length === 0) return true;

    const ch0 = input[0]!;
    const ch1 = input.length > 1 ? input[1]! : ch0;
    const frames = ch0.length;

    for (let i = 0; i < frames; i++) {
      const l = Math.abs(ch0[i] ?? 0);
      const r = Math.abs(ch1[i] ?? 0);
      if (l > this.ctx.peakL) this.ctx.peakL = l;
      if (r > this.ctx.peakR) this.ctx.peakR = r;
      this.ctx.sumSquaredL += (ch0[i] ?? 0) ** 2;
      this.ctx.sumSquaredR += (ch1[i] ?? 0) ** 2;
    }
    this.ctx.frameCount += frames;

    if (this.ctx.frameCount >= WINDOW_FRAMES) {
      const rmsL = Math.sqrt(this.ctx.sumSquaredL / this.ctx.frameCount);
      const rmsR = Math.sqrt(this.ctx.sumSquaredR / this.ctx.frameCount);
      this.port.postMessage({
        peakL: toDbfs(this.ctx.peakL),
        peakR: toDbfs(this.ctx.peakR),
        rmsL: toDbfs(rmsL),
        rmsR: toDbfs(rmsR),
      });
      this.ctx = freshContext();
    }
    return true;
  }
}

registerProcessor('wave-meter', WaveMeterProcessor);
