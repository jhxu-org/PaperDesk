import {MAX_BYTES, CHUNK_BYTES, httpURL, looksLikePDF, toBase64} from './pdf-utils.js';
import {createHandoff} from './import-handoff.js';
const HOST = 'com.paperdesk.browser';
let activeJob = null;

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => chrome.contextMenus.create({id:'paperdesk-import', title:'导入 PDF 到 PaperDesk', contexts:['link','page','frame'], documentUrlPatterns:['http://*/*','https://*/*']}));
});
chrome.contextMenus.onClicked.addListener((info, tab) => {
  const url = httpURL(info.linkUrl || info.frameUrl || info.pageUrl);
  if (info.menuItemId !== 'paperdesk-import' || !url) return;
  createHandoff(chrome.storage.session, url, tab?.title).then(request =>
    chrome.tabs.create({url: chrome.runtime.getURL('popup.html') + '?' + new URLSearchParams({request})})
  ).catch(() => status({state:'error', message:'无法准备 PDF 导入，请重新打开扩展后重试。'}));
});

class NativeConnection {
  constructor() {
    this.port = chrome.runtime.connectNative(HOST);
    this.pending = null;
    this.closed = false;
    this.port.onMessage.addListener(message => {
      const pending = this.pending; this.pending = null;
      if (!pending) return;
      clearTimeout(pending.timer);
      if (message.ok) pending.resolve(message);
      else pending.reject(new Error(message.message || 'PaperDesk 未能接收文件。'));
    });
    this.port.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError;
      this.closed = true;
      const pending = this.pending; this.pending = null;
      if (pending) {
        clearTimeout(pending.timer);
        pending.reject(new Error(error ? '尚未连接 PaperDesk。请打开 Mac 应用 →「Chrome 扩展」→「启用连接」，再重试。' : '与 PaperDesk 的连接已断开。'));
      }
    });
  }
  send(message) {
    if (this.closed) return Promise.reject(new Error('与 PaperDesk 的连接已断开。'));
    return new Promise((resolve,reject) => {
      const timer = setTimeout(() => { this.pending=null; this.close(); reject(new Error('PaperDesk 响应超时，请检查应用是否正常打开。')); },45000);
      this.pending={resolve,reject,timer};
      try { this.port.postMessage(message); } catch (error) { clearTimeout(timer); this.pending=null; reject(error); }
    });
  }
  close() { this.closed=true; this.port.disconnect(); }
}
async function status(value) { await chrome.storage.session.set({importStatus:{...value,updatedAt:Date.now()}}); }
async function runImport(request) {
  if (activeJob) throw new Error('已有一份 PDF 正在导入，请等待完成。');
  const url = httpURL(request.url);
  if (!url) throw new Error('仅支持网页上的 HTTP / HTTPS PDF。blob 文件请先下载后导入。');
  const controller = new AbortController();
  activeJob = controller;
  let native;
  const timeout = setTimeout(() => controller.abort(),180000);
  try {
    await status({state:'working',message:'正在连接 PaperDesk…',percent:0});
    native = new NativeConnection();
    await native.send({type:'ping'});
    await status({state:'working',message:'正在获取 PDF…',percent:0});
    const response = await fetch(url,{credentials:'include',signal:controller.signal});
    if (!response.ok) throw new Error(`网站返回 HTTP ${response.status}。请确认可以在浏览器中正常下载此 PDF。`);
    if (!response.body) throw new Error('网站没有返回文件内容。');
    const total = Number(response.headers.get('content-length')) || 0;
    if (total > MAX_BYTES) throw new Error('文件超过 100 MB，请下载后从 PaperDesk 导入。');
    const type = response.headers.get('content-type') || '';
    if (/text\/html/i.test(type)) throw new Error('此地址返回的是网页。请打开真正的 PDF，或在页面中选择 PDF 下载链接。');
    const reader = response.body.getReader();
    let received=0, sequence=0, first=new Uint8Array(), began=false;
    const sendChunk = async bytes => {
      for (let offset=0; offset<bytes.length; offset+=CHUNK_BYTES) {
        controller.signal.throwIfAborted();
        await native.send({type:'chunk',sequence:sequence++,data:toBase64(bytes.subarray(offset,offset+CHUNK_BYTES))});
      }
    };
    while (true) {
      const {value,done} = await reader.read();
      if (done) break;
      received += value.length;
      if (received > MAX_BYTES) throw new Error('文件超过 100 MB，请下载后从 PaperDesk 导入。');
      if (!began) {
        const merged=new Uint8Array(first.length+value.length); merged.set(first); merged.set(value,first.length); first=merged;
        if (first.length < 1024) continue;
        if (!looksLikePDF(first)) throw new Error('下载结果不是 PDF。网站可能要求登录，或此链接是普通网页。');
        await native.send({type:'begin',title:String(request.title || '网页 PDF').slice(0,160),sourceURL:response.url || url});
        began=true; await sendChunk(first); first=new Uint8Array();
      } else await sendChunk(value);
      await status({state:'working',message:`正在传输 ${(received/1024/1024).toFixed(1)} MB…`,percent:total?Math.min(95,Math.round(received/total*95)):null});
    }
    if (!began) {
      if (!looksLikePDF(first)) throw new Error('网站没有返回有效的 PDF。');
      await native.send({type:'begin',title:String(request.title || '网页 PDF').slice(0,160),sourceURL:response.url || url});
      await sendChunk(first);
    }
    controller.signal.throwIfAborted();
    clearTimeout(timeout);
    await status({state:'working',message:'正在加入 PaperDesk 书库…',percent:98});
    const result = await native.send({type:'finish',byteCount:received});
    await status({state:'done',message:result.message || '已导入 PaperDesk',percent:100});
    return {ok:true};
  } catch (error) {
    controller.abort();
    const message=error.name === 'AbortError' ? '导入已取消或下载超时，可以重新尝试。' : error.message || '导入失败。';
    await status({state:'error',message});
    return {ok:false,message};
  } finally {
    clearTimeout(timeout); native?.close(); activeJob=null;
  }
}
chrome.runtime.onMessage.addListener((message,sender,reply) => {
  // Only our own popup/import page may trigger a privileged download. No page messaging bridge.
  if (sender.id !== chrome.runtime.id || sender.url?.split('?')[0] !== chrome.runtime.getURL('popup.html')) return;
  if (message.type === 'import') {
    runImport(message).then(reply).catch(error=>reply({ok:false,message:error.message})); return true;
  }
  if (message.type === 'cancel') { activeJob?.abort(); reply({ok:true}); }
  if (message.type === 'ping') {
    const native = new NativeConnection();
    native.send({type:'ping'}).then(()=>reply({ok:true})).catch(error=>reply({ok:false,message:error.message})).finally(()=>native.close()); return true;
  }
});
