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
| renderer → network (fetch / XHR / WebSocket) | renderer XSS exfiltrating diagnostic data | CSP `connect-src 'self' https://api.wave.online wss://api.wave.online` blocks `fetch`/`XHR`/`WebSocket` to unlisted origins — including the WHEP signaling fetch, which CSP DOES cover. **Does NOT govern WebRTC media transport (`RTCPeerConnection`)** — see WebRTC row for that |
| WebRTC peer connection | malicious SDP from a hijacked gateway endpoint, or renderer XSS opening an RTC pipe to an attacker | RTC peer lives in the **renderer** (MediaStream objects can't cross IPC). Defenses: (a) `addTransceiver` with `direction: 'recvonly'` for both audio and video locks the SDP direction at offer time — gateway can't trick us into sending; (b) no `getUserMedia` / display-capture calls anywhere in the renderer — there is no surface for an attacker to pivot through into the operator's mic/camera; (c) the signaling fetch's URL goes through `connect-src` CSP, so XSS can't redirect signaling to an attacker host. ICE servers default to STUN-only; gateway-supplied TURN credentials are scoped to the active session |
| renderer → external URL (in-window nav, `window.open`, redirect) | renderer XSS forcing the window to load attacker-controlled content | three-handler hardening in `src/main/index.ts`: `setWindowOpenHandler` + `will-navigate` + `will-redirect` all hand non-internal http(s) URLs to `shell.openExternal` and cancel the in-window navigation; everything else is dropped |
| Audio worklet → main | high-rate IPC fan-in DoS | meter samples are local-only; never sent to network |

## Out-of-scope

- Physical access to the operator's machine
- Browser-level vulnerabilities in Chromium (track upstream)
- Operator pasting a non-WAVE URL — request validation rejects non-WAVE origins at the main-process boundary; CSP only enforces this for renderer-initiated fetch/XHR/WebSocket and does NOT cover WebRTC or main-process traffic
