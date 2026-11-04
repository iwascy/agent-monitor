// node --test scripts/test-paseo-bridge.cjs
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {checksum,readRegistry,snappy,records,tableEntries,connectionURI,publicAgent,snapshot} = require('../Sources/AgentMonitorCore/Resources/PaseoBridge.cjs');
const B = Buffer;
function v(n) { const a=[];do { a.push((n&127)|(n>127?128:0)); n=Math.floor(n/128); } while(n); return B.from(a); }
function field(b) { return B.concat([v(b.length),b]); }
function record(b,type=1) { const h=B.alloc(7);h.writeUInt16LE(b.length,4);h[6]=type;h.writeUInt32LE(checksum(B.concat([B.from([type]),b])));return B.concat([h,b]); }
function batch(seq,value,key='@paseo:daemon-registry') {
  const h=B.alloc(12);h.writeBigUInt64LE(BigInt(seq));h.writeUInt32LE(1,8);
  const k=B.concat([B.from('_file://\0\x01'),B.from(key)]);
  return B.concat([h,B.from([value===null?0:1]),field(k),...(value===null?[]:[field(B.concat([B.from([1]),B.from(JSON.stringify(value))]))])]);
}
function temp(t) {const p=fs.mkdtempSync(path.join(os.tmpdir(),'paseo-test-'));t.after(()=>fs.rmSync(p,{recursive:true,force:true}));return p;}
function registry(dir,hosts) {
  fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'CURRENT'),'MANIFEST-000001\n');
  fs.writeFileSync(path.join(dir,'MANIFEST-000001'),record(B.from([2,9])));
  fs.writeFileSync(path.join(dir,'000009.log'),record(batch(1,hosts)));
}
function block(entries) {
  const content=B.concat(entries.map(([k,data])=>B.concat([v(0),v(k.length),v(data.length),k,data])));
  const restarts=B.alloc(8);restarts.writeUInt32LE(1,4);return B.concat([content,restarts]);
}
function diskBlock(data) {const raw=B.concat([data,B.from([0])]);const sum=B.alloc(4);sum.writeUInt32LE(checksum(raw));return B.concat([raw,sum]);}
function table(key,value) {
  const data=diskBlock(block([[key,value]]));const indexData=block([[key,B.concat([v(0),v(data.length-5)])]]);
  const index=diskBlock(indexData);const footer=B.alloc(48);
  B.concat([v(0),v(0),v(data.length),v(indexData.length)]).copy(footer);B.from('57fb808b247547db','hex').copy(footer,40);
  return B.concat([data,index,footer]);
}

test('reads live WAL, ignores partial batches, applies tombstones, and never resurrects obsolete logs',t=>{
  const p=temp(t);registry(p,[{serverId:'one'}]);
  fs.writeFileSync(path.join(p,'000008.log'),record(batch(999,[{serverId:'obsolete'}])));
  fs.appendFileSync(path.join(p,'000009.log'),record(batch(2,[{serverId:'two'}])));
  assert.equal(readRegistry(p)[0].serverId,'two');
  fs.appendFileSync(path.join(p,'000009.log'),record(batch(3,null)));
  assert.deepEqual(readRegistry(p),[]);
  const partial=record(batch(4,[{serverId:'partial'}]));fs.appendFileSync(path.join(p,'000009.log'),partial.subarray(0,-3));
  assert.deepEqual(readRegistry(p),[]);
});
test('reassembles fragmented records and rejects corruption',()=>{
  const full=B.concat([record(B.from('abc'),2),record(B.from('def'),4)]);
  assert.equal(records(full)[0].toString(),'abcdef');
  full[8]^=1;assert.throws(()=>records(full),/checksum/);
});
test('decodes sstable blocks and Snappy overlapping copies; rejects corrupt block data',()=>{
  const b=table(B.from('key'),B.from('value'));assert.deepEqual(tableEntries(b),[[B.from('key'),B.from('value')]]);
  b[1]^=1;assert.throws(()=>tableEntries(b),/checksum/);
  assert.equal(snappy(B.from([6,4,97,98,14,2,0])).toString(),'ababab');
  assert.throws(()=>snappy(B.from([6,4,97,98,14,0,0])));
});
test('uses manifest live tables and UTF-16 Chromium values',t=>{
  const p=temp(t);registry(p,[]);fs.unlinkSync(path.join(p,'000009.log'));
  const key=B.from('_file://\0\x01@paseo:daemon-registry');const tag=B.alloc(8);tag.writeBigUInt64LE((10n<<8n)|1n);
  const data=table(B.concat([key,tag]),B.concat([B.from([0]),B.from(JSON.stringify([{serverId:'远程'}]),'utf16le')]));
  fs.writeFileSync(path.join(p,'000010.ldb'),data);
  const edit=B.concat([v(7),v(0),v(10),v(data.length),field(B.from('a')),field(B.from('z'))]);
  fs.appendFileSync(path.join(p,'MANIFEST-000001'),record(edit));
  assert.equal(readRegistry(p)[0].serverId,'远程');
  fs.appendFileSync(path.join(p,'MANIFEST-000001'),record(B.from([6,0,10])));
  assert.deepEqual(readRegistry(p),[]);
});
test('SSH / TLS / relay connection grammar and metadata allowlist',()=>{
  assert.equal(connectionURI({type:'remoteSsh',host:'user@host',sshPort:2222,daemonPort:6768}),'ssh://user@host:2222?daemonPort=6768');
  assert.throws(()=>connectionURI({type:'remoteSsh',host:'-oProxyCommand=bad'}));
  assert.equal(connectionURI({type:'directTcp',endpoint:'localhost:6767',useTls:true}),'tcp://127.0.0.1:6767?ssl=true');
  const offer=JSON.parse(B.from(connectionURI({type:'relay',serverId:'srv',relayEndpoint:'relay:80',daemonPublicKeyB64:'key'}).split('#offer=')[1],'base64url'));
  assert.equal(offer.v,2);assert.equal(offer.serverId,'srv');
  const out=publicAgent({id:'a',password:'secret',config:{token:'secret'},runtimeInfo:{sessionId:'native',extra:{secret:'bad'}},pendingPermissions:[{}]});
  assert.deepEqual(out,{id:'a',runtimeInfo:{sessionId:'native'},pendingPermission:true});
});
test('snapshot follows only saved hosts, paginates, validates identity, and routes through saved origins',async t=>{
  const home=temp(t),app=path.join(home,'Paseo.app');const sdk=path.join(app,'Contents/Resources/app.asar/node_modules/@getpaseo/client/dist');fs.mkdirSync(path.join(sdk,'node'),{recursive:true});
  // Fake the installed SDK at its boundary, including a host with a colliding native ID.
  fs.writeFileSync(path.join(sdk,'node/index.js'),`const calls=[];globalThis.paseoCalls=calls;
    class Client {
      constructor(id){this.id=id;this.pages=0;calls.push(['open',id]);}
      async connect(){} getLastServerInfoMessage(){return {serverId:this.id==='mismatch'?'wrong':this.id};}
      async fetchAgents(q){calls.push(['fetch',this.id,q]);this.pages++;return {entries:[{agent:{id:this.id+'-'+this.pages,provider:'codex',runtimeInfo:{sessionId:'same-native'},password:'secret'}}],pageInfo:{hasMore:this.pages===1,nextCursor:'page2'}};}
      async close(){calls.push(['close',this.id]);}
    }
    exports.Client=Client;exports.createHostClient=(uri)=>new Client(uri.includes('remote')?'remote':uri.includes('mismatch')?'mismatch':'local');
    exports.createHostChannelTransport=(origin,id)=>({id});`);
  fs.writeFileSync(path.join(sdk,'daemon-client.js'),`const {Client}=require('./node/index.js');exports.DaemonClient=class extends Client{constructor(c){super(c.transportFactory.id)}};`);
  fs.mkdirSync(path.join(home,'.paseo'));fs.writeFileSync(path.join(home,'.paseo/server-id'),'local');
  registry(path.join(home,'Library/Application Support/Paseo/Local Storage/leveldb'),[
    {serverId:'local',label:'Mac',connections:[{type:'directTcp',endpoint:'localhost:6767'}]},
    {serverId:'remote',label:'远程',connections:[{type:'remoteSsh',host:'remote'}]},
    {serverId:'routed',connections:[{type:'routed',originServerId:'local'}]},
    {serverId:'mismatch',connections:[{type:'directTcp',endpoint:'mismatch:6767'}]},
  ]);
  const result=await snapshot(app,home);
  assert.deepEqual(result.map(h=>[h.serverID,h.isLocal,h.connected,h.agents.length]),[
    ['local',true,true,2],['remote',false,true,2],['routed',false,true,2],['mismatch',false,false,0]]);
  assert.ok(globalThis.paseoCalls.filter(c=>c[0]==='fetch').every(c=>c[2].filter.includeArchived===false));
  assert.equal(result[1].agents[0].password,undefined);
  assert.equal(globalThis.paseoCalls.filter(c=>c[0]==='close').length,5); // failed identity closes before final cleanup
});
