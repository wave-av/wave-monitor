import { useState } from 'react';
import type { MonitorState } from '@shared/ipc';
import { Meters } from './Meters';

interface Props {
  state: MonitorState;
  onChange: (next: MonitorState) => void;
}

export function Monitor({ state, onChange }: Props): React.JSX.Element {
  const [draftUrl, setDraftUrl] = useState('');
  const [busy, setBusy] = useState(false);

  const connect = async (): Promise<void> => {
    setBusy(true);
    try {
      const next = await window.wave.monitor.start({ feedUrl: draftUrl });
      onChange(next);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error(err);
    } finally {
      setBusy(false);
    }
  };

  const disconnect = async (): Promise<void> => {
    setBusy(true);
    try {
      const next = await window.wave.monitor.stop();
      onChange(next);
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
