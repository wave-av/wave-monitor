/**
 * Renderer-side WebRTC viewer client.
 *
 * Protocol: WebRTC-HTTP Egress Protocol (WHEP) — POST an SDP offer to the feed
 * URL, get an SDP answer back, apply. This is the same shape OBS / VLC use
 * for pulling streams from media servers, so the WAVE gateway implements it
 * for both player browsers and us.
 *
 * MediaStream objects can't cross the Electron IPC boundary — they're
 * GPU-process-bound — so WebRTC HAS to live in the renderer. The threat
 * surface is intentional: this view ONLY pulls feeds, never publishes, never
 * exposes any device, and the only outbound URL is the operator-typed
 * feedUrl which is also pinned by CSP connect-src.
 *
 * Cleanup ordering matters: stop() tears down the track first, then closes
 * the peer, then aborts any in-flight signaling fetch. Reversing the order
 * leaves the gateway thinking we're still connected for ~30s of ICE timeout.
 */

export interface FeedConnection {
  stream: MediaStream;
  close: () => void;
}

interface ConnectOptions {
  feedUrl: string;
  /** ICE servers to try. Default is a single Google STUN — works for most NATs;
   * the gateway also includes its own TURN in the SDP. */
  iceServers?: RTCIceServer[];
  /** Outer abort propagates to the signaling fetch + any pending negotiation. */
  signal?: AbortSignal;
}

const DEFAULT_ICE: RTCIceServer[] = [{ urls: 'stun:stun.l.google.com:19302' }];
const SIGNAL_TIMEOUT_MS = 15_000;

export async function connectFeed(opts: ConnectOptions): Promise<FeedConnection> {
  const pc = new RTCPeerConnection({
    iceServers: opts.iceServers ?? DEFAULT_ICE,
    // Receive-only — defense against a buggy/hostile gateway that adds an
    // ICE candidate that would try to negotiate microphone access.
    iceTransportPolicy: 'all',
  });

  // We expect audio + video. Adding the transceivers up-front locks the SDP
  // direction to recvonly so the gateway can't trick us into sending media.
  pc.addTransceiver('video', { direction: 'recvonly' });
  pc.addTransceiver('audio', { direction: 'recvonly' });

  // Collect tracks into a single MediaStream — this is what the <video>
  // element + audio worklet will both consume.
  const stream = new MediaStream();
  pc.ontrack = (ev: RTCTrackEvent) => {
    for (const track of ev.streams[0]?.getTracks() ?? [ev.track]) {
      if (!stream.getTracks().find((t) => t.id === track.id)) {
        stream.addTrack(track);
      }
    }
  };

  // Cleanup chain — registered before the awaits so a mid-flight abort
  // doesn't leak the peer connection.
  let aborted = false;
  const innerController = new AbortController();
  const onOuterAbort = (): void => {
    aborted = true;
    innerController.abort();
  };
  opts.signal?.addEventListener('abort', onOuterAbort, { once: true });

  const close = (): void => {
    aborted = true;
    opts.signal?.removeEventListener('abort', onOuterAbort);
    for (const t of stream.getTracks()) t.stop();
    try {
      pc.close();
    } catch {
      /* already closed */
    }
  };

  try {
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    // Wait for ICE gathering to finish so we POST a complete SDP — gateway-
    // side WHEP implementations don't always support trickle ICE.
    await waitIceGathering(pc, innerController.signal);

    if (aborted || !pc.localDescription) throw new DOMException('aborted', 'AbortError');

    const timer = setTimeout(() => innerController.abort(), SIGNAL_TIMEOUT_MS);
    let answerSdp: string;
    try {
      const res = await fetch(opts.feedUrl, {
        method: 'POST',
        headers: {
          'content-type': 'application/sdp',
          accept: 'application/sdp',
        },
        body: pc.localDescription.sdp,
        signal: innerController.signal,
      });
      if (!res.ok) {
        throw new Error(`gateway returned ${res.status}`);
      }
      answerSdp = await res.text();
    } finally {
      clearTimeout(timer);
    }

    if (aborted) throw new DOMException('aborted', 'AbortError');

    await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });
    return { stream, close };
  } catch (err) {
    close();
    throw err;
  }
}

function waitIceGathering(pc: RTCPeerConnection, signal: AbortSignal): Promise<void> {
  if (pc.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise<void>((resolve, reject) => {
    const onAbort = (): void => {
      pc.removeEventListener('icegatheringstatechange', check);
      reject(new DOMException('aborted', 'AbortError'));
    };
    const check = (): void => {
      if (pc.iceGatheringState === 'complete') {
        signal.removeEventListener('abort', onAbort);
        pc.removeEventListener('icegatheringstatechange', check);
        resolve();
      }
    };
    pc.addEventListener('icegatheringstatechange', check);
    signal.addEventListener('abort', onAbort, { once: true });
  });
}
