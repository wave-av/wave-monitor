// local-feed.mjs — loopback stub of the generic update feed for the
// staged-rollout simulation (scripts/rollout-sim.sh). Serves:
//   /rollout.json   {version, rollout} per --version/--rollout
//   /latest-mac.yml a minimal electron-updater manifest fixture
// Prints {"url": ...} on stdout once bound. Never touches the network.
import http from 'node:http';

const args = process.argv.slice(2);
const flag = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};

const VERSION = flag('version', '0.2.0');
// Fail-closed on a non-numeric flag: NaN would serialize as null downstream.
const _rollout = Number(flag('rollout', '1'));
const ROLLOUT = Number.isFinite(_rollout) ? _rollout : 1;

const server = http.createServer((req, res) => {
  if (req.url === '/rollout.json') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ version: VERSION, rollout: ROLLOUT }));
    return;
  }
  if (req.url === '/latest-mac.yml') {
    res.writeHead(200, { 'content-type': 'text/yaml' });
    res.end(
      [
        `version: ${VERSION}`,
        'files:',
        `  - url: WAVE Monitor-${VERSION}-arm64-mac.zip`,
        '    sha512: QUJDREVGRklDVFVCRklDVEVSUUVNVA==',
        `    size: 123456`,
        'path: WAVE Monitor-0.1.0-arm64-mac.zip',
        'sha512: QUJDREVGRklDVFVCRklDVEVSUUVNVA==',
        'releaseDate: 2026-10-19T00:00:00.000Z',
        '',
      ].join('\n'),
    );
    return;
  }
  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(0, '127.0.0.1', () => {
  console.log(JSON.stringify({ url: `http://127.0.0.1:${server.address().port}` }));
});
