/**
 * Cross-process IPC contract for wave-monitor.
 *
 * Single concern: tell main which feed to monitor, get back live audio
 * meter samples. No multi-tab, no encoder state, no persistence.
 */

import { z } from 'zod';

export const MonitorStateSchema = z.object({
  feedUrl: z.string().nullable(),
  connected: z.boolean(),
  /** dBFS, -inf..0 — clamped client-side. */
  peakL: z.number(),
  peakR: z.number(),
  rmsL: z.number(),
  rmsR: z.number(),
});
export type MonitorState = z.infer<typeof MonitorStateSchema>;

export const StartRequestSchema = z.object({
  feedUrl: z.string().url(),
});
export type StartRequest = z.infer<typeof StartRequestSchema>;

export const IPC = {
  monitorState: 'wave:monitor:state',
  monitorStart: 'wave:monitor:start',
  monitorStop: 'wave:monitor:stop',
} as const;
export type IpcChannel = (typeof IPC)[keyof typeof IPC];
