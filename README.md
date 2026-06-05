# wave-monitor

**Lightweight audio + video monitor for any WAVE feed.** Paste a feed URL, hit Connect, see signal. Equivalent of NDI Studio Monitor + NDI Audio Monitor, but for WAVE.

Built on `@wave-av/sdk`. ~300 lines of app code. Also a **"Build on WAVE" demo** — what every customer can build on top of the public SDK.

## What it does

- Single window: video preview on the left, dual-channel peak+RMS audio meters on the right
- Paste any `https://api.wave.online/feed/...` URL or stream key
- Connect / Disconnect
- That's it — no encoding, no multiview, no settings. Open it, confirm signal, close it.

## Why this exists

Every operator's first question: "is my stream actually live?" Today the answer involves opening the WAVE web app, signing in, navigating to a dashboard. After wave-monitor ships, the answer is "double-click the WAVE Monitor icon, paste, done."

Also serves as the smallest, cleanest example of building on the WAVE SDK — bundled with every wave-desktop release and shipped standalone at `downloads.wave.online/monitor`.

## Quick start

```sh
git clone https://github.com/wave-av/wave-monitor.git
cd wave-monitor
npm install
npm run dev
```

`npm run dist:mac` produces a `.dmg` for arm64 + x64.

## Architecture

```text
┌── renderer (CSP-locked) ───────────────────┐
│  React UI:                                  │
│  ┌─ URL bar + Connect ──────────────────┐  │
│  │ <video> + peak/RMS meters             │  │
│  └────────────────────────────────────────┘  │
└────────────────────┬───────────────────────┘
                     │ IPC (Zod-validated)
┌────────────────────▼───────────────────────┐
│  main                                       │
│  · RTCPeerConnection to gateway (W2)        │
│  · AudioWorkletProcessor → peak/RMS         │
└────────────────────┬───────────────────────┘
                     │ WebRTC + JWT (Bearer)
                     ▼
             api.wave.online
```

## Roadmap

| Wave | Surface | Status |
|---|---|---|
| W1 | This scaffold (Electron shell + IPC + meter component) | this PR |
| W2 | Real WebRTC pull from gateway + audio worklet computing peak/RMS @ 20Hz | next |
| W3 | Multi-window: open N monitors simultaneously, drag between displays | pending |
| W4 | Always-on-top toggle + transparent-window mode (overlay use) | pending |

## License

[MIT](./LICENSE). No vendor-licensed binaries; all rendering uses standard
WebRTC + Web Audio APIs.

---

<!-- wave-standard-footer -->
<sub><b><a href="https://wave.online">wave.online</a></b> &nbsp;·&nbsp; <a href="https://docs.wave.online">Docs</a> &nbsp;·&nbsp; <a href="https://dev.wave.online">Developers</a> &nbsp;·&nbsp; <a href="https://agents.wave.online">For agents</a></sub>
