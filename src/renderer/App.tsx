import { useEffect, useState } from 'react';
import type { MonitorState } from '@shared/ipc';
import { Monitor } from './views/Monitor';

export function App(): React.JSX.Element {
  const [state, setState] = useState<MonitorState | null>(null);
  const [pollError, setPollError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    let polling = false;

    const tick = async (): Promise<void> => {
      if (polling) return; // skip if previous poll still in flight
      polling = true;
      try {
        const next = await window.wave.monitor.state();
        if (!cancelled) {
          setState(next);
          setPollError(null);
        }
      } catch (err) {
        if (!cancelled) {
          setPollError(err instanceof Error ? err.message : 'unknown');
        }
      } finally {
        polling = false;
      }
    };

    void tick();
    const interval = setInterval(tick, 50);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, []);

  return (
    <div className="flex h-screen flex-col">
      <header className="wave-drag flex items-center justify-between border-b border-zinc-800 bg-zinc-950 px-4 py-2">
        <span className="text-sm font-semibold tracking-wide">WAVE Monitor</span>
        <span className="text-xs text-zinc-500">
          {pollError
            ? `disconnected (${pollError})`
            : state?.connected
              ? state.feedUrl
              : 'idle'}
        </span>
      </header>
      <main className="flex-1 overflow-hidden">
        {state ? <Monitor state={state} onChange={setState} /> : null}
      </main>
    </div>
  );
}
