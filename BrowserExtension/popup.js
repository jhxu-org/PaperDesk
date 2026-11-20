import {candidatesFrom, httpURL} from './pdf-utils.js';
import {consumeHandoff} from './import-handoff.js';
const $ = id => document.getElementById(id);
let candidates=[], busy=false;
function renderStatus(value) {
  if (!value) return;
  $('status').hidden=false; $('status').dataset.state=value.state;
  $('message').textContent=value.message;
  busy=value.state==='working';
  $('check').disabled=busy;
  $('import').disabled=busy || !candidates.length;
  $('cancel').hidden=!busy || value.percent===98;
  $('progress').hidden=!busy;
  if (typeof value.percent==='number') $('progress').value=value.percent;
  else $('progress').removeAttribute('value');
}
function renderCandidates() {
  $('candidates').replaceChildren();
  candidates.forEach((item,index)=>{
    const label=document.createElement('label'); label.className='candidate';
    const input=document.createElement('input'); input.type='radio'; input.name='pdf'; input.value=index; input.checked=index===0;
    const info=document.createElement('div'); info.className='info';
    for (const [className,text] of [['kind',item.kind],['title',item.title],['domain',new URL(item.url).hostname]]) {
      const line=document.createElement('div'); line.className=className; line.textContent=text; info.append(line);
    }
    label.append(input,info); $('candidates').append(label);
  });
  $('empty').hidden=!!candidates.length;
  $('import').disabled=!candidates.length || busy;
}
async function initialize() {
  const params=new URLSearchParams(location.search);
  if (params.has('request')) {
    const pending = await consumeHandoff(chrome.storage.session, params.get('request'));
    if (!pending) {
      renderCandidates();
      renderStatus({state:'error',message:'此导入链接已过期或已使用，请在原网页重新选择导入。'});
      return;
    }
    candidates=candidatesFrom(pending,[{...pending,kind:'选择的 PDF 链接'}]);
  } else {
    const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
    if (!tab) { renderCandidates(); return; }
    let found=[];
    try {
      const [result]=await chrome.scripting.executeScript({target:{tabId:tab.id},func:()=>{
        const result=[];
        const add=(url,title,kind)=>{if(url)result.push({url,title,kind});};
        for (const meta of document.querySelectorAll('meta[name="citation_pdf_url"],meta[property="citation_pdf_url"]')) add(meta.content,document.title,'论文 PDF');
        for (const node of document.querySelectorAll('embed,object,iframe')) {
          const url=node.src || node.data;
          if (node.type==='application/pdf' || /\.pdf(?:$|[?#])/i.test(url || '')) add(url,node.title || document.title,'内嵌 PDF');
        }
        for (const link of document.querySelectorAll('a[href]')) {
          if (link.type==='application/pdf' || /\.pdf(?:$|[?#])/i.test(link.href) || /\.pdf$/i.test(link.download || '')) add(link.href,link.textContent.trim() || link.download || document.title,'PDF 链接');
          if(result.length>=60) break;
        }
        return result;
      }});
      found=result?.result || [];
    } catch { /* Chrome's built-in PDF viewer does not allow script injection; use the tab URL. */ }
    candidates=candidatesFrom(tab,found);
  }
  renderCandidates();
  const {importStatus}=await chrome.storage.session.get('importStatus');
  if (importStatus && Date.now()-importStatus.updatedAt < 5*60*1000) renderStatus(importStatus);
}
$('import').addEventListener('click',async()=>{
  const index=Number(document.querySelector('input[name=pdf]:checked')?.value || 0);
  const item=candidates[index]; if(!item || busy) return;
  try {
    // Request only this origin, synchronously from the user's click (no intervening await).
    const url=new URL(httpURL(item.url));
    const granted=await chrome.permissions.request({origins:[`${url.protocol}//${url.hostname}/*`]});
    if (!granted) { renderStatus({state:'error',message:'未获得此网站的访问权限，未下载文件。'}); return; }
    renderStatus({state:'working',message:'正在开始导入…',percent:0});
    const result=await chrome.runtime.sendMessage({type:'import',url:item.url,title:item.title});
    if (!result?.ok) renderStatus({state:'error',message:result?.message || '连接已中断，请重新尝试。'});
  } catch (error) {renderStatus({state:'error',message:error.message});}
});
$('cancel').addEventListener('click',()=>chrome.runtime.sendMessage({type:'cancel'}));
$('check').addEventListener('click',async()=>{
  $('check').disabled=true;
  try {const result=await chrome.runtime.sendMessage({type:'ping'});renderStatus({state:result.ok?'done':'error',message:result.ok?'已连接 Mac 上的 PaperDesk。':result.message});}
  catch {renderStatus({state:'error',message:'无法连接，请重新加载扩展。'});}
  finally {$('check').disabled=busy;}
});
chrome.storage.onChanged.addListener((changes,area)=>{if(area==='session' && changes.importStatus)renderStatus(changes.importStatus.newValue);});
initialize().catch(()=>{renderStatus({state:'error',message:'无法读取此页面。请打开 HTTP / HTTPS PDF 后重试。'});renderCandidates();});
