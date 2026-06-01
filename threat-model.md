# wave-monitor threat model

## Scope

Single-window Electron app that pulls a WAVE feed over WebRTC and renders
it locally. No upload path, no recording, no persistence beyond the
in-memory monitor state.

## Trust boundaries

| Boundary | Threat | Defense |
|---|---|---|
| operator-typed URL | malformed URL → renderer crash | `StartRequestSchema.parse()` rejects non-URLs at the main boundary |
| renderer → main | renderer compromise injecting feed-control commands | Zod validation on every IPC payload; channel allowlist (3 channels only) |
| renderer → network (fetch / XHR / WebSocket) | renderer XSS exfiltrating diagnostic data | CSP `connect-src 'self' https://api.wave.online wss://api.wave.online` blocks `fetch`/`XHR`/`WebSocket` to unlisted origins. **Does NOT govern WebRTC `RTCPeerConnection`** — see WebRTC row |
| WebRTC peer connection | malicious SDP from a hijacked gateway endpoint, or renderer XSS opening an RTC pipe to an attacker | the RTC peer is created in the **main process** (per architecture in README), which is not bound by the renderer CSP. Renderer is blocked from `RTCPeerConnection` because main never exposes a preload bridge for it. Defense is "no surface", not CSP. W2 adds gateway TLS pinning + ICE candidate filtering at the main-process layer |
| renderer → external URL (in-window nav, `window.open`, redirect) | renderer XSS forcing the window to load attacker-controlled content | three-handler hardening in `src/main/index.ts`: `setWindowOpenHandler` + `will-navigate` + `will-redirect` all hand non-internal http(s) URLs to `shell.openExternal` and cancel the in-window navigation; everything else is dropped |
| Audio worklet → main | high-rate IPC fan-in DoS | meter samples are local-only; never sent to network |

## Out-of-scope

- Physical access to the operator's machine
- Browser-level vulnerabilities in Chromium (track upstream)
- Operator pasting a non-WAVE URL — request validation rejects non-WAVE origins at the main-process boundary; CSP only enforces this for renderer-initiated fetch/XHR/WebSocket and does NOT cover WebRTC or main-process traffic
