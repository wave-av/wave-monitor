/**
 * Wire schemas for the wave-monitor control-plane HTTP API.
 *
 * Adapted from wave-desktop's control-plane types for the monitor surface:
 * status/start/stop/version. Both sides — the server handlers here AND any
 * Companion module or script that talks to this plane — derive types from
 * these schemas so a wire-protocol change cannot drift silently.
 */

import { z } from 'zod';

// ── status / health ─────────────────────────────────────────────────────────

export const StatusResponseSchema = z.object({
  /** Module is alive and the API key matched. */
  ok: z.literal(true),
  /** wave-monitor semver (from package.json). */
  version: z.string(),
  /** ISO-8601 instant the server bound the socket. */
  bootAt: z.iso.datetime(),
  /** Number of seconds the API has been running. */
  uptimeSec: z.number().int().nonnegative(),
  /** True iff a feed is currently bound. */
  connected: z.boolean(),
  /** Bound feed URL, or null when idle. */
  feedUrl: z.url().nullable(),
});
export type StatusResponse = z.infer<typeof StatusResponseSchema>;

// ── version ─────────────────────────────────────────────────────────────────

export const VersionResponseSchema = z.object({
  name: z.string(),
  version: z.string(),
});
export type VersionResponse = z.infer<typeof VersionResponseSchema>;

// ── errors ──────────────────────────────────────────────────────────────────

export const ErrorResponseSchema = z.object({
  error: z.string(),
  /** Optional machine-readable code (e.g. "AUTH_REQUIRED", "BAD_REQUEST"). */
  code: z.string().optional(),
});
export type ErrorResponse = z.infer<typeof ErrorResponseSchema>;
