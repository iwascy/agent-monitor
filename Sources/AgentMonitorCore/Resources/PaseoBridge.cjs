// Read-only bridge to Paseo's own SDK and Chromium's saved host registry.
// No daemon starts, session resumes, messages, or credential-file reads.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const MAX = 64 * 1024 * 1024;
function checksum(b) {
  let crc = 0xffffffff;
  for (const byte of b) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0x82f63b78 : 0);
  }
  crc = (~crc) >>> 0;
  return (((crc >>> 15) | (crc << 17)) + 0xa282ead8) >>> 0;
}
function varint(b, cursor) {
  let value = 0, factor = 1;
  for (let i = 0; i < 10; i++) {
    if (cursor.p >= b.length) throw Error('truncated varint');
    const x = b[cursor.p++]; value += (x & 127) * factor;
    if (!(x & 128)) { if (!Number.isSafeInteger(value)) throw Error('large varint'); return value; }
    factor *= 128;
  }
  throw Error('invalid varint');
}
function slice(b, c, n) {
  if (n < 0 || n > MAX || c.p + n > b.length) throw Error('truncated block');
  const result = b.subarray(c.p, c.p + n); c.p += n; return result;
}
function bytes(b, c) { return slice(b, c, varint(b, c)); }
function snappy(b) {
  const c = {p: 0}, size = varint(b, c);
  if (size > MAX) throw Error('large snappy block');
  const out = Buffer.alloc(size); let p = 0;
  while (c.p < b.length && p < size) {
    const tag = b[c.p++], type = tag & 3;
    let n, offset;
    if (type === 0) {
      n = tag >>> 2;
      if (n < 60) n++;
      else { const count = n - 59; n = slice(b, c, count).readUIntLE(0, count) + 1; }
      const literal = slice(b, c, n);
      if (p + n > size) throw Error('invalid literal');
      literal.copy(out, p); p += n; continue;
    }
    if (type === 1) { n = 4 + ((tag >>> 2) & 7); offset = ((tag & 224) << 3) + slice(b, c, 1)[0]; }
    else { n = 1 + (tag >>> 2); offset = slice(b, c, type === 2 ? 2 : 4).readUIntLE(0, type === 2 ? 2 : 4); }
    if (!offset || offset > p || p + n > size) throw Error('invalid copy');
    for (let i = 0; i < n; i++) { out[p] = out[p - offset]; p++; }
  }
  if (p !== size || c.p !== b.length) throw Error('incomplete snappy block');
  return out;
}
function records(b) {
  const result = []; let fragments = null;
  for (let base = 0; base < b.length; base += 32768) {
    const end = Math.min(base + 32768, b.length); let p = base;
    while (p + 7 <= end) {
      const n = b.readUInt16LE(p + 4), type = b[p + 6]; p += 7;
      if (!type && !n) break;
      if (p + n > end) break; // concurrent/incomplete final write
      const part = b.subarray(p, p + n);
      if (b.readUInt32LE(p - 7) !== checksum(Buffer.concat([Buffer.from([type]),part]))) throw Error("invalid log checksum");
      p += n;
      if (type === 1) { result.push(part); fragments = null; }
      else if (type === 2) fragments = [part];
      else if (type === 3 && fragments) fragments.push(part);
      else if (type === 4 && fragments) { result.push(Buffer.concat([...fragments, part])); fragments = null; }
    }
  }
  return result;
}
function entries(b) {
  if (b.length < 4) throw Error('invalid table');
  const end = b.length - 4 * (b.readUInt32LE(b.length - 4) + 1);
  if (end < 0) throw Error('invalid restart array');
  const c = {p: 0}, result = []; let key = Buffer.alloc(0);
  while (c.p < end) {
    const shared = varint(b, c), n = varint(b, c), size = varint(b, c);
    if (shared > key.length) throw Error('invalid shared key');
    key = Buffer.concat([key.subarray(0, shared), slice(b, c, n)]);
    result.push([key, slice(b, c, size)]);
  }
  return result;
}
function tableEntries(b) {
  if (b.length < 48 || b.subarray(-8).toString('hex') !== '57fb808b247547db') throw Error('invalid table footer');
  const c = {p: b.length - 48}; varint(b, c); varint(b, c);
  const offset = varint(b, c), size = varint(b, c);
  function block(offset, size) {
    if (offset + size + 5 > b.length) throw Error('invalid block handle');
    const data = b.subarray(offset, offset + size), type = b[offset + size];
    if (b.readUInt32LE(offset + size + 1) !== checksum(b.subarray(offset,offset + size + 1))) throw Error("invalid block checksum");
    if (type === 0) return data;
    if (type === 1) return snappy(data);
    throw Error('unsupported compression');
  }
  const result = [];
  for (const [, handle] of entries(block(offset, size))) {
    const h = {p: 0}; result.push(...entries(block(varint(handle, h), varint(handle, h))));
  }
  return result;
}
function readFile(file) {
  if (fs.statSync(file).size > MAX) throw Error('large database file');
  return fs.readFileSync(file);
}
function activeFiles(dir) {
  const current = fs.readFileSync(path.join(dir, 'CURRENT'), 'utf8').trim();
  if (!/^MANIFEST-\d+$/.test(current)) throw Error('invalid manifest');
  const tables = new Set(); let log = 0, previous = 0;
  for (const r of records(readFile(path.join(dir, current)))) {
    const c = {p: 0};
    while (c.p < r.length) {
      const tag = varint(r, c);
      if (tag === 1) bytes(r, c);
      else if (tag === 2) log = varint(r, c);
      else if (tag === 9) previous = varint(r, c);
      else if (tag === 3 || tag === 4) varint(r, c);
      else if (tag === 5) { varint(r, c); bytes(r, c); }
      else if (tag === 6) { varint(r, c); tables.delete(varint(r, c)); }
      else if (tag === 7) { varint(r, c); tables.add(varint(r, c)); varint(r, c); bytes(r, c); bytes(r, c); }
      else throw Error('unsupported manifest');
    }
  }
  return fs.readdirSync(dir).filter(name => {
    const m = /^(\d+)\.(ldb|sst|log)$/.exec(name);
    return m && (m[2] === 'log' ? Number(m[1]) >= log || Number(m[1]) === previous : tables.has(Number(m[1])));
  });
}
function readRegistry(dir) {
  let newest = -1n, value = null;
  function accept(key, data, seq, type) {
    // Chromium localStorage: _<origin> NUL <encoding byte><key>.
    const zero = key.indexOf(0);
    if (key[0] !== 95 || zero < 0) return;
    const encoded = key.subarray(zero + 1);
    const text = encoded.subarray(1).toString(encoded[0] === 0 ? 'utf16le' : 'latin1');
    if (text !== '@paseo:daemon-registry' || seq <= newest) return;
    newest = seq;
    value = type === 0 ? null : data.subarray(1).toString(data[0] === 0 ? 'utf16le' : 'latin1');
  }
  for (const file of activeFiles(dir)) {
    const b = readFile(path.join(dir, file));
    if (!file.endsWith('.log')) {
      for (const [key, data] of tableEntries(b)) {
        if (key.length < 8) continue;
        const tag = key.readBigUInt64LE(key.length - 8);
        accept(key.subarray(0, -8), data, tag >> 8n, Number(tag & 255n));
      }
    } else for (const batch of records(b)) {
      if (batch.length < 12) continue;
      const seq = batch.readBigUInt64LE(0), count = batch.readUInt32LE(8), c = {p: 12};
      const pending = [];
      try {
        for (let i = 0; i < count; i++) {
          const type = slice(batch, c, 1)[0];
          if (type !== 0 && type !== 1) throw Error('invalid write');
          const key = bytes(batch, c), data = type === 1 ? bytes(batch, c) : Buffer.alloc(0);
          pending.push([key, data, seq + BigInt(i), type]);
        }
        if (c.p !== batch.length) throw Error('invalid batch');
        for (const entry of pending) accept(...entry);
      } catch { /* Do not accept partial writes. */ }
    }
  }
  const hosts = value === null ? [] : JSON.parse(value);
  if (!Array.isArray(hosts)) throw Error('invalid host registry');
  return hosts;
}
function connectionURI(c) {
  if (c.type === 'directTcp') {
    const endpoint = c.endpoint.replace(/^localhost(?=:)/, '127.0.0.1');
    return `tcp://${endpoint}${c.useTls ? '?ssl=true' : ''}`;
  }
  if (c.type === 'directSocket') return `unix://${c.path}`;
  if (c.type === 'remoteSsh') {
    if (!c.host || /\s/.test(c.host) || c.host.startsWith('-')) throw Error('invalid SSH host');
    const at = c.host.lastIndexOf('@');
    const user = at < 0 ? '' : encodeURIComponent(c.host.slice(0, at)) + '@';
    const host = at < 0 ? c.host : c.host.slice(at + 1);
    return `ssh://${user}${host.includes(':') && !host.startsWith('[') ? `[${host}]` : host}${c.sshPort ? `:${c.sshPort}` : ''}?daemonPort=${c.daemonPort ?? 6767}`;
  }
  if (c.type === 'relay') {
    // The SDK parses the same connection offer used by Paseo desktop.
    const offer = {v:2, serverId: c.serverId, daemonPublicKeyB64: c.daemonPublicKeyB64,
      relay: {endpoint: c.relayEndpoint, ...(c.useTls === undefined ? {} : {useTls:c.useTls})},
      ...(c.minimumSecurityMode ? {minimumSecurityMode:c.minimumSecurityMode} : {})};
    return `https://paseo.sh/#offer=${Buffer.from(JSON.stringify(offer)).toString('base64url')}`;
  }
  throw Error('unsupported connection');
}
function publicAgent(a) {
  // Explicit allowlist: never return connection passwords or provider config.
  const result = {};
  for (const key of ['id','provider','cwd','title','status','lastStatus','createdAt','updatedAt','lastActivityAt',
    'requiresAttention','attentionReason','attentionTimestamp','archivedAt','archived','isArchived','internal','runtimeInfo','persistence']) {
    if (a[key] !== undefined) result[key] = a[key];
  }
  result.pendingPermission = !!a.pendingPermissions?.length;
  // Only identity is needed from provider runtime/persistence metadata.
  for (const key of ['runtimeInfo','persistence']) if (result[key]) result[key] = {sessionId:result[key].sessionId};
  return result;
}
async function snapshot(app, home) {
  const sdkRoot = path.join(app, 'Contents/Resources/app.asar/node_modules/@getpaseo');
  const {createHostClient, createHostChannelTransport} = require(path.join(sdkRoot, 'client/dist/node/index.js'));
  const {DaemonClient} = require(path.join(sdkRoot, 'client/dist/daemon-client.js'));
  const noop = () => {}, logger = {debug:noop, info:noop, warn:noop, error:noop};
  let hosts = [];
  const registry = path.join(home, 'Library/Application Support/Paseo/Local Storage/leveldb');
  if (fs.existsSync(registry)) hosts = readRegistry(registry);
  let localID = null;
  try { localID = fs.readFileSync(path.join(home,'.paseo/server-id'),'utf8').trim(); } catch {}
  if (localID && !hosts.some(h => h.serverId === localID)) {
    let listen = '127.0.0.1:6767';
    try { listen = JSON.parse(fs.readFileSync(path.join(home,'.paseo/paseo.pid'),'utf8')).listen ?? listen; } catch {}
    hosts.push({serverId:localID,label:'本机',connections:[{type:'directTcp',endpoint:listen}]});
  }
  const allClients = new Set();
  let disposing = false;
  process.once('SIGTERM', () => {
    disposing = true;
    Promise.allSettled([...allClients].map(c=>c.close())).finally(()=>process.exit(1));
  });
  const clients = new Map(), results = new Map(), opening = new Map();
  const config = () => ({clientId:require('node:crypto').randomUUID(),logger,
    connectTimeoutMs:2500,reconnect:{enabled:false},appVersion:'0.13.2'});
  async function openHost(h, ancestry = new Set()) {
    if (ancestry.has(h.serverId)) throw Error('cyclic host route');
    if (clients.has(h.serverId)) return clients.get(h.serverId);
    if (opening.has(h.serverId)) return opening.get(h.serverId);
    const chain = new Set([...ancestry,h.serverId]);
    // Defer until the promise is memoized, so concurrent routed hosts share an origin.
    const attempt = Promise.resolve().then(async () => {
      const connections = [...h.connections].sort((a,b) => Number(b.id === h.preferredConnectionId) - Number(a.id === h.preferredConnectionId));
      for (const c of connections) {
        if (disposing) throw Error('bridge closing');
        let client;
        try {
          if (c.type === 'routed') {
            const origin = hosts.find(x => x.serverId === c.originServerId);
            if (!origin) continue;
            const upstream = await openHost(origin,chain);
            if (disposing) throw Error('bridge closing');
            client = new DaemonClient({...config(),url:'ws://routed-host/ws',
              transportFactory:createHostChannelTransport(upstream,h.serverId,require('node:crypto').randomUUID(),null)});
          } else client = createHostClient(connectionURI({...c,serverId:h.serverId}), {
            ...config(), ...(h.password || c.password ? {password:h.password || c.password} : {})});
          allClients.add(client);
          await client.connect();
          if (disposing || client.getLastServerInfoMessage()?.serverId !== h.serverId) throw Error('host identity mismatch');
          clients.set(h.serverId,client); return client;
        } catch { if (client) await client.close().catch(noop); }
      }
      throw Error('host offline');
    });
    opening.set(h.serverId,attempt);
    return attempt;
  }
  async function readHost(h) {
    const result = {serverID:h.serverId,hostName:h.label || h.hostname || h.serverId,isLocal:h.serverId===localID,connected:false,agents:[]};
    results.set(h.serverId,result);
    let timer;
    const deadline = new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('host timeout')),6000);});
    try {
      const agents = await Promise.race([deadline,(async()=>{
        const client = await openHost(h); let cursor;
        const agents = [], cursors = new Set();
        do {
          const page = await client.fetchAgents({filter:{includeArchived:false,includeInternal:false},page:{limit:200,...(cursor?{cursor}:{})},timeout:2500});
          agents.push(...page.entries.map(e=>publicAgent(e.agent)));
          const next = page.pageInfo.hasMore ? page.pageInfo.nextCursor : null;
          if (next && cursors.has(next)) throw Error('repeated page cursor');
          if (next) cursors.add(next);
          cursor = next;
        } while (cursor && !disposing);
        return agents;
      })()]);
      result.agents = agents;
      result.connected = true;
    } catch { /* One offline host must not prevent healthy hosts from updating. */ }
    finally { clearTimeout(timer); }
  }
  try {
    await Promise.all(hosts.map(readHost));
    return [...results.values()];
  } finally {
    disposing = true;
    for (const c of allClients) await c.close().catch(noop);
  }
}
module.exports = {checksum, readRegistry, snappy, records, tableEntries, connectionURI, publicAgent, snapshot};
if (require.main === module) {
  // Do not forward SDK errors: they can contain endpoints or credentials.
  snapshot(process.argv[2],process.argv[3] || os.homedir())
    .then(hosts=>process.stdout.write(JSON.stringify(hosts)))
    .catch(()=>{process.exitCode=1;});
}
