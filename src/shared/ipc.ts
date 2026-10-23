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
  /** dBFS, -inf..0 — clamped client-side. Nullable because the HTTP control
   *  plane serves this state as JSON, and JSON.stringify renders the
   *  silence value (-Infinity) as null. IPC (structured-clone) preserves
   *  -Infinity; HTTP consumers must treat null as silence. */
  peakL: z.number().nullable(),
  peakR: z.number().nullable(),
  rmsL: z.number().nullable(),
  rmsR: z.number().nullable(),
});
export type MonitorState = z.infer<typeof MonitorStateSchema>;

export const StartRequestSchema = z.object({
  feedUrl: z.string().url(),
});
export type StartRequest = z.infer<typeof StartRequestSchema>;

import { IPC } from './channels';

export { IPC };
export type IpcChannel = (typeof IPC)[keyof typeof IPC];

/**
 * Auto-update snapshot served over IPC.updateStatus. States: idle,
 * checking, up-to-date, available, deferred (rollout gate), ready, error.
 * Shape mirrors the create-wave-app electron template's updater.js.  # guard:allow electron template attribution
 */
export type UpdateState =
  | 'idle'
  | 'checking'
  | 'up-to-date'
  | 'available'
  | 'deferred'
  | 'ready'
  | 'error';

export interface UpdateSnapshot {
  state: UpdateState;
  version: string | null;
  error: string | null;
  feed: string;
}
