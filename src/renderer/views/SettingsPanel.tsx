import { useEffect, useState } from 'react';
import type { UpdateSnapshot } from '@shared/ipc';

/**
 * Settings: control-plane API key reveal/copy/rotate + auto-update status.
 *
 * The key is the Bearer [REDACTED] for the loopback control plane (paste into
 * Companion / vMix config). It crosses IPC only behind these explicit
 * buttons — never on load, never on a timer.
 */
export function SettingsPanel(): React.JSX.Element {
  const [apiKey, setApiKey] = useState<string | null>(null);
  const [keyMsg, setKeyMsg] = useState<string | null>(null);
  const [update, setUpdate] = useState<UpdateSnapshot | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    window.wave.updates
      .status()
      .then((s) => {
        if (!cancelled) setUpdate(s);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, []);

  const reveal = async (): Promise<void> => {
    setBusy(true);
    setKeyMsg(null);
    try {
      const key = await window.wave.controlPlane.revealKey();
      setApiKey(key);
      if (key === null) setKeyMsg('control plane unavailable');
    } catch (err) {
      setKeyMsg(err instanceof Error ? err.message : 'reveal failed');
    } finally {
      setBusy(false);
    }
  };

  const copy = async (): Promise<void> => {
    if (!apiKey) return;
    try {
      await navigator.clipboard.writeText(apiKey);
      setKeyMsg('copied to clipboard');
    } catch {
      setKeyMsg('copy failed — select the key manually');
    }
  };

  const rotate = async (): Promise<void> => {
    setBusy(true);
    setKeyMsg(null);
    try {
      const key = await window.wave.controlPlane.rotateKey();
      setApiKey(key);
      setKeyMsg(key === null ? 'control plane unavailable' : 'rotated — update Companion config');
    } catch (err) {
      setKeyMsg(err instanceof Error ? err.message : 'rotate failed');
    } finally {
      setBusy(false);
    }
  };

  const checkUpdates = async (): Promise<void> => {
    setBusy(true);
    try {
      setUpdate(await window.wave.updates.check());
    } catch {
      /* status() poll on next mount; nothing to show mid-flight */
    } finally {
      setBusy(false);
    }
  };

  const install = async (): Promise<void> => {
    setBusy(true);
    try {
      await window.wave.updates.install();
    } finally {
      setBusy(false);
    }
  };

  return (
    <details className="border-t border-zinc-800 bg-zinc-950 px-4 py-2">
      <summary className="cursor-pointer text-xs font-medium text-zinc-400">Settings</summary>
      <div className="flex flex-col gap-3 py-3">
        <div className="flex flex-col gap-2">
          <span className="text-xs font-medium text-zinc-300">Control-plane API key</span>
          <div className="flex items-center gap-2">
            {apiKey === null ? (
              <button
                type="button"
                onClick={reveal}
                disabled={busy}
                className="min-h-9 rounded border border-zinc-700 px-3 text-xs text-zinc-200 hover:bg-zinc-800 disabled:opacity-50"
              >
                Reveal key
              </button>
            ) : (
              <>
                <code className="max-w-64 truncate rounded bg-zinc-900 px-2 py-1 font-mono text-xs text-zinc-200">
                  {apiKey}
                </code>
                <button
                  type="button"
                  onClick={copy}
                  className="min-h-9 rounded border border-zinc-700 px-3 text-xs text-zinc-200 hover:bg-zinc-800"
                >
                  Copy
                </button>
                <button
                  type="button"
                  onClick={() => setApiKey(null)}
                  className="min-h-9 rounded border border-zinc-700 px-3 text-xs text-zinc-200 hover:bg-zinc-800"
                >
                  Hide
                </button>
              </>
            )}
            <button
              type="button"
              onClick={rotate}
              disabled={busy}
              className="min-h-9 rounded border border-zinc-700 px-3 text-xs text-zinc-200 hover:bg-zinc-800 disabled:opacity-50"
            >
              Rotate
            </button>
          </div>
          {keyMsg ? <span className="text-xs text-zinc-500">{keyMsg}</span> : null}
        </div>
        <div className="flex flex-col gap-2">
          <span className="text-xs font-medium text-zinc-300">Updates</span>
          <div className="flex items-center gap-2">
            <span className="text-xs text-zinc-500">
              {update ? `${update.state}${update.version ? ` · ${update.version}` : ''}` : '…'}
            </span>
            <button
              type="button"
              onClick={checkUpdates}
              disabled={busy}
              className="min-h-9 rounded border border-zinc-700 px-3 text-xs text-zinc-200 hover:bg-zinc-800 disabled:opacity-50"
            >
              Check for updates
            </button>
            {update?.state === 'ready' ? (
              <button
                type="button"
                onClick={install}
                disabled={busy}
                className="min-h-9 rounded bg-[var(--wave-accent)] px-3 text-xs font-medium text-zinc-950 disabled:opacity-50"
              >
                Restart to install
              </button>
            ) : null}
          </div>
          {update?.error ? <span className="text-xs text-red-400">{update.error}</span> : null}
        </div>
      </div>
    </details>
  );
}
