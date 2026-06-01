/**
 * Two-channel peak + RMS bars, -60..0 dBFS.
 *
 * Color zones (broadcast convention):
 *   -60..-18 dBFS  green   safe
 *   -18..-6  dBFS  yellow  hot
 *   -6..0    dBFS  red     clipping risk
 */

interface MeterProps {
  peakL: number;
  peakR: number;
  rmsL: number;
  rmsR: number;
}

const MIN_DB = -60;

function normalize(db: number): number {
  if (!Number.isFinite(db)) return 0;
  const clamped = Math.max(MIN_DB, Math.min(0, db));
  return (clamped - MIN_DB) / -MIN_DB; // 0..1
}

export function Meters({ peakL, peakR, rmsL, rmsR }: MeterProps): React.JSX.Element {
  return (
    <div className="grid grid-cols-2 gap-2">
      <Channel label="L" peak={peakL} rms={rmsL} />
      <Channel label="R" peak={peakR} rms={rmsR} />
    </div>
  );
}

function Channel({
  label,
  peak,
  rms,
}: {
  label: string;
  peak: number;
  rms: number;
}): React.JSX.Element {
  const peakPct = normalize(peak) * 100;
  const rmsPct = normalize(rms) * 100;
  return (
    <div className="flex flex-col items-center gap-1">
      <div className="relative h-full w-6 rounded bg-zinc-900">
        <div
          className="absolute inset-x-0 bottom-0 rounded bg-gradient-to-t from-green-500 via-yellow-400 to-red-500 opacity-90"
          style={{ height: `${rmsPct}%` }}
        />
        <div
          className="absolute inset-x-0 h-0.5 bg-zinc-100"
          style={{ bottom: `${peakPct}%` }}
        />
      </div>
      <span className="text-xs font-medium text-zinc-400">{label}</span>
      <span className="text-[10px] text-zinc-500">
        {Number.isFinite(peak) ? peak.toFixed(0) : '−∞'} dB
      </span>
    </div>
  );
}
