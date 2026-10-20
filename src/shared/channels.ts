/**
 * Bare IPC channel names — zero imports on purpose.
 *
 * The sandboxed preload script cannot `require()` bare packages (not even
 * ones bundled into out/), so it imports the runtime `IPC` map from here
 * while taking all *types* via `import type` from `@shared/ipc` (erased at
 * compile time). `@shared/ipc` re-exports this map, so main/renderer keep
 * importing from the one familiar place.
 */

export const IPC = {
  monitorState: 'wave:monitor:state',
  monitorStart: 'wave:monitor:start',
  monitorStop: 'wave:monitor:stop',
  monitorMediaLive: 'wave:monitor:media-live',
  revealApiKey: 'wave:monitor:reveal-api-key',
  rotateApiKey: 'wave:monitor:rotate-api-key',
  updateStatus: 'wave:monitor:update-status',
  checkForUpdates: 'wave:monitor:check-for-updates',
  installUpdate: 'wave:monitor:install-update',
} as const;
