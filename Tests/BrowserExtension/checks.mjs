import assert from 'node:assert/strict';
import test from 'node:test';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {candidatesFrom,httpURL,looksLikePDF,toBase64,CHUNK_BYTES} from '../../BrowserExtension/pdf-utils.js';
import {createHandoff,consumeHandoff} from '../../BrowserExtension/import-handoff.js';
const manifest=JSON.parse(readFileSync(new URL('../../BrowserExtension/manifest.json',import.meta.url)));
const id=[...createHash('sha256').update(Buffer.from(manifest.key,'base64')).digest('hex').slice(0,32)].map(x=>String.fromCharCode(97+parseInt(x,16))).join('');

test('stable extension identity matches native allowlist',()=>{
  const native=readFileSync(new URL('../../Sources/PaperDeskCore/BrowserIntegration.swift',import.meta.url),'utf8');
  assert.ok(native.includes(`extensionID = "${id}"`));
  assert.equal(manifest.manifest_version,3);
  assert.equal(manifest.host_permissions,undefined);
  assert.equal(manifest.externally_connectable,undefined);
});
test('detect direct, embedded, metadata and query PDF links; deduplicate safely',()=>{
  const results=candidatesFrom({url:'https://example.org/article',title:'Research'},[
    {url:'/download?file=paper.pdf',title:'Download'},
    {url:'https://example.org/download?file=paper.pdf#page=2'},
    {url:'/embedded.pdf',kind:'内嵌 PDF'},
    {url:'javascript:alert(1)'},{url:'file:///etc/passwd'},{url:'https://user:password@example.org/private'}]);
  assert.equal(results.length,2);
  assert.equal(results[0].url,'https://example.org/download?file=paper.pdf');
  assert.equal(candidatesFrom({url:'https://example.org/current.pdf',title:'PDF'})[0].kind,'当前 PDF');
  assert.equal(candidatesFrom({url:'chrome://extensions',title:'Extensions'}).length,0);
  assert.equal(httpURL('blob:https://example.org/file'),null);
});
test('PDF header is checked as bytes; binary chunks survive Base64',()=>{
  assert.ok(looksLikePDF(new TextEncoder().encode('\n%PDF-1.7\n')));
  assert.ok(!looksLikePDF(new TextEncoder().encode('<html>login</html>')));
  const bytes=Uint8Array.from({length:CHUNK_BYTES},(_,i)=>i%256);
  assert.deepEqual(Buffer.from(toBase64(bytes),'base64'),Buffer.from(bytes));
});
test('native executable speaks framed UTF-8 and rejects unauthorized callers',()=>{
  const binary=fileURLToPath(new URL('../../.build/debug/PaperDeskBridge',import.meta.url));
  const frame=object=>{const bytes=Buffer.from(JSON.stringify(object)),header=Buffer.alloc(4);header.writeUInt32LE(bytes.length);return Buffer.concat([header,bytes]);};
  const invalid=spawnSync(binary,['chrome-extension://invalid/'],{input:frame({type:'ping'})});
  assert.equal(invalid.stdout.length,0);
  const result=spawnSync(binary,[`chrome-extension://${id}/`],{input:Buffer.concat([frame({type:'ping'}),frame({type:'chunk',sequence:0,data:'YWJj'})])});
  assert.equal(result.status,0);
  let cursor=0;
  const read=()=>{const count=result.stdout.readUInt32LE(cursor);cursor+=4;const value=JSON.parse(result.stdout.subarray(cursor,cursor+count));cursor+=count;return value;};
  assert.equal(read().version,'0.3.0');
  assert.equal(read().ok,false);
  assert.equal(cursor,result.stdout.length);
});

let onMessage, fetched=0, mode='pdf', nativeMessages=[], status, createdTab;
const records = {};
const storage = {
  async get(key){return key === null ? {...records} : {[key]:records[key]};},
  async set(value){Object.assign(records,value);if(value.importStatus)status=value.importStatus;},
  async remove(keys){for(const key of Array.isArray(keys)?keys:[keys])delete records[key];}
};
function event(){let listener;return {addListener(fn){listener=fn;},dispatch(...values){return listener?.(...values);}};}
globalThis.chrome={
  runtime:{id,onInstalled:event(),getURL:path=>`chrome-extension://${id}/${path}`,
    onMessage:{addListener(fn){onMessage=fn;}},connectNative(){
      const port={onMessage:event(),onDisconnect:event(),postMessage(message){nativeMessages.push(message);queueMicrotask(()=>port.onMessage.dispatch({ok:true,message:'Imported'}));},disconnect(){port.onDisconnect.dispatch();}};return port;
    }},
  contextMenus:{onClicked:event(),removeAll(){},create(){}},tabs:{create(value){createdTab=value;}},
  storage:{session:storage}
};
globalThis.fetch=async()=>{
  fetched++;
  if(mode==='html') return new Response('<html>login</html>',{headers:{'content-type':'text/html'}});
  if(mode==='auth') return new Response('denied',{status:403});
  if(mode==='fake') return new Response('ordinary text',{headers:{'content-type':'application/pdf'}});
  if(mode==='oversized') return new Response('%PDF-1.7',{headers:{'content-length':String(101*1024*1024)}});
  const bytes=new Uint8Array(400000);bytes.set(new TextEncoder().encode('%PDF-1.7\n'));
  return new Response(bytes,{headers:{'content-type':'application/pdf','content-length':String(bytes.length)}});
};
await import('../../BrowserExtension/background.js');
const send=message=>new Promise(resolve=>onMessage(message,{id,url:chrome.runtime.getURL('popup.html')},resolve));
test('context-menu handoff keeps signed URLs and titles out of the tab address',async()=>{
  const signedURL='https://example.org/private.pdf?signature=synthetic-private-value';
  chrome.contextMenus.onClicked.dispatch({menuItemId:'paperdesk-import',linkUrl:signedURL},{title:'Private paper title'});
  await new Promise(resolve=>setImmediate(resolve));
  const url=new URL(createdTab.url);
  assert.deepEqual([...url.searchParams.keys()],['request']);
  assert.ok(!createdTab.url.includes('signature'));
  assert.ok(!createdTab.url.includes('Private'));
  const request=url.searchParams.get('request');
  assert.deepEqual(await consumeHandoff(storage,request),{url:signedURL,title:'Private paper title'});
  assert.equal(await consumeHandoff(storage,request),null);
});
test('import handoffs expire, reject invalid IDs and retain at most twenty pending records',async()=>{
  const start=Date.now();
  const expired=await createHandoff(storage,'https://example.org/p.pdf','p',start);
  assert.equal(await consumeHandoff(storage,expired,start+300000),null);
  assert.equal(await consumeHandoff(storage,'importStatus'),null);
  for(let i=0;i<25;i++)await createHandoff(storage,'https://example.org/p.pdf','p',start+i);
  assert.equal(Object.keys(records).filter(key=>key.startsWith('pendingImport:')).length,20);
});
test('worker transfers bounded ordered chunks and reports acknowledged success',async()=>{
  nativeMessages=[];mode='pdf';
  assert.equal((await send({type:'import',url:'https://example.org/research.pdf',title:'Research'})).ok,true);
  const chunks=nativeMessages.filter(x=>x.type==='chunk');
  assert.ok(chunks.length>1);
  chunks.forEach((chunk,index)=>{assert.equal(chunk.sequence,index);assert.ok(Buffer.from(chunk.data,'base64').length<=CHUNK_BYTES);});
  assert.equal(Buffer.concat(chunks.map(x=>Buffer.from(x.data,'base64'))).length,400000);
  assert.equal(nativeMessages.at(-1).byteCount,400000);
  assert.equal(status.state,'done');
});
test('worker rejects HTML, unauthenticated, mislabeled and oversized downloads',async()=>{
  for(mode of ['html','auth','fake','oversized']){
    nativeMessages=[];
    assert.equal((await send({type:'import',url:'https://example.org/file',title:'Research'})).ok,false);
    assert.ok(!nativeMessages.some(x=>x.type==='finish'));
    assert.equal(status.state,'error');
  }
});
test('web content cannot invoke privileged download handler',()=>{
  const before=fetched;
  const result=onMessage({type:'import',url:'https://example.org/file'},{id,url:'https://untrusted.example/page'},()=>assert.fail('must not reply'));
  assert.equal(result,undefined);assert.equal(fetched,before);
});
