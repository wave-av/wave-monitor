import { useEffect, useState } from 'react';
import type { MonitorState } from '@shared/ipc';
import { Monitor } from './views/Monitor';

export function App(): React.JSX.Element {
  const [state, setState] = useState<MonitorState | null>(null);

  useEffect(() => {
    void window.wave.monitor.state().then(setState);
    const interval = setInterval(() => {
      void window.wave.monitor.state().then(setState);
    }, 50);
    return () => clearInterval(interval);
  }, []);

  return (
    <div className="flex h-screen flex-col">
      <header
        className="flex items-center justify-between border-b border-zinc-800 bg-zinc-950 px-4 py-2"
        style={{ WebkitAppRegion: 'drag' } as React.CSSProperties}
      >
        <span className="text-sm font-semibold tracking-wide">WAVE Monitor</span>
        <span className="text-xs text-zinc-500">
          {state?.connected ? state.feedUrl : 'idle'}
        </span>
      </header>
      <main className="flex-1 overflow-hidden">
        {state ? <Monitor state={state} onChange={setState} /> : null}
      </main>
    </div>
  );
}
