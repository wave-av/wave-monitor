import { useState } from 'react';
import type { MonitorState } from '@shared/ipc';
import { Meters } from './Meters';

interface Props {
  state: MonitorState;
  onChange: (next: MonitorState) => void;
}

/**
 * Sanitize an error for the UI without leaking the feed URL / stream key.
 * IPC rejects shouldn't carry the secret, but defense-in-depth: show only
 * the error class name + first 80 chars of message after a `_` strip pass.
 */
function safeErrMsg(err: unknown): string {
  const raw = err instanceof Error ? `${err.name}: ${err.message}` : 'unknown error';
  return raw.replace(/(token|key|feedurl)[=:]\S+/gi, '$1=[redacted]').slice(0, 120);
}

export function Monitor({ state, onChange }: Props): React.JSX.Element {
  const [draftUrl, setDraftUrl] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const connect = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const next = await window.wave.monitor.start({ feedUrl: draftUrl });
      onChange(next);
    } catch (err) {
      setError(safeErrMsg(err));
    } finally {
      setBusy(false);
    }
  };

  const disconnect = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const next = await window.wave.monitor.stop();
      onChange(next);
    } catch (err) {
      setError(safeErrMsg(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="grid h-full grid-cols-[1fr_120px] gap-4 p-4">
      <div className="flex flex-col gap-3">
        <div className="flex items-center gap-2">
          <input
            type="url"
            value={draftUrl}
            onChange={(e) => setDraftUrl(e.target.value)}
            placeholder="https://api.wave.online/feed/your-stream-key"
            disabled={state.connected || busy}
            className="min-h-11 flex-1 rounded border border-zinc-700 bg-zinc-900 px-3 text-sm text-zinc-200 placeholder:text-zinc-600 focus:border-[var(--wave-accent)] focus:outline-none"
          />
          {state.connected ? (
            <button
              type="button"
              onClick={disconnect}
              disabled={busy}
              className="min-h-11 rounded border border-zinc-700 px-4 text-sm text-zinc-200 hover:bg-zinc-800"
            >
              Disconnect
            </button>
          ) : (
            <button
              type="button"
              onClick={connect}
              disabled={busy || draftUrl.length === 0}
              className="min-h-11 rounded bg-[var(--wave-accent)] px-4 text-sm font-medium text-zinc-950 disabled:opacity-50"
            >
              Connect
            </button>
          )}
        </div>
        {error ? (
          <div
            role="alert"
            className="rounded border border-red-500/40 bg-red-500/10 px-3 py-2 text-xs text-red-400"
          >
            {error}
          </div>
        ) : null}
        <div className="flex-1 rounded-lg border border-zinc-800 bg-black">
          {state.connected ? (
            <video
              autoPlay
              playsInline
              muted={false}
              controls={false}
              className="h-full w-full rounded-lg object-contain"
            />
          ) : (
            <div className="grid h-full place-items-center text-sm text-zinc-600">
              Paste a WAVE feed URL above and hit Connect.
            </div>
          )}
        </div>
      </div>
      <Meters peakL={state.peakL} peakR={state.peakR} rmsL={state.rmsL} rmsR={state.rmsR} />
    </div>
  );
}
