/**
 * Attach an AudioWorklet to a MediaStream's audio tracks. The worklet posts
 * peak/RMS samples (in dBFS) at ~20Hz; this module exposes a clean
 * subscribe/cleanup surface for the React layer.
 *
 * The AudioWorklet module is loaded via a Vite ?worker-style URL import so
 * the bundler emits it as a separate JS file at build time. We can't `eval`
 * the processor here because AudioWorklet APIs require the module URL to be
 * fetchable + sandboxed.
 *
 * Sample handlers run in renderer microtasks — they should be cheap (we batch
 * to 20Hz on the worklet side specifically so React state updates are sane).
 */

// Vite handles the ?url suffix at build time, emitting the worklet as a
// hashed standalone bundle next to main.js.
import workletUrl from './audio-meter-worklet?worker&url';

export interface MeterSample {
  peakL: number;
  peakR: number;
  rmsL: number;
  rmsR: number;
}

export interface MeterHandle {
  close: () => void;
}

let cachedCtx: AudioContext | null = null;

function getAudioContext(): AudioContext {
  if (!cachedCtx) {
    cachedCtx = new AudioContext({ latencyHint: 'interactive' });
  }
  return cachedCtx;
}

export async function attachMeter(
  stream: MediaStream,
  onSample: (sample: MeterSample) => void,
): Promise<MeterHandle> {
  const ctx = getAudioContext();
  // AudioContext may have been suspended by autoplay policy — resume on
  // first attach. No-op if already running.
  if (ctx.state === 'suspended') {
    await ctx.resume();
  }
  await ctx.audioWorklet.addModule(workletUrl);

  const source = ctx.createMediaStreamSource(stream);
  const node = new AudioWorkletNode(ctx, 'wave-meter');
  node.port.onmessage = (ev: MessageEvent<MeterSample>) => onSample(ev.data);

  source.connect(node);
  // Do NOT connect node to ctx.destination — we don't want to round-trip
  // monitor audio through the meter and back out the speakers; the <video>
  // element plays the audio directly.

  return {
    close: () => {
      try {
        node.port.onmessage = null;
        source.disconnect();
        node.disconnect();
      } catch {
        /* already disconnected */
      }
    },
  };
}
