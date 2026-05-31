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
| renderer → network | renderer XSS exfiltrating frames | CSP `connect-src 'self' https://api.wave.online wss://api.wave.online`; no third-party origins |
| WebRTC peer connection | malicious SDP from a hijacked gateway endpoint | gateway TLS pinning (W2); ICE candidate filtering (W2) |
| Audio worklet → main | high-rate IPC fan-in DoS | meter samples are local-only; never sent to network |

## Out-of-scope

- Physical access to the operator's machine
- Browser-level vulnerabilities in Chromium (track upstream)
- Operator pasting a non-WAVE URL — `connect-src` blocks the actual fetch
