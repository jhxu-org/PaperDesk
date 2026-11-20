export const MAX_BYTES = 100 * 1024 * 1024;
export const CHUNK_BYTES = 192 * 1024;
export function httpURL(value, base) {
  try {
    const url = new URL(value, base);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) return null;
    url.hash = '';
    return url.href;
  } catch { return null; }
}
export function isPDFLink(value) {
  const url = httpURL(value);
  if (!url) return false;
  const parsed = new URL(url);
  return /\.pdf$/i.test(parsed.pathname) || [...parsed.searchParams.values()].some(v => /\.pdf(?:$|[?#])/i.test(v));
}
export function candidatesFrom(tab, found = []) {
  const candidates = [], seen = new Set();
  for (const item of found) {
    const url = httpURL(item.url, tab.url);
    if (!url || seen.has(url)) continue;
    seen.add(url);
    candidates.push({ url, title: String(item.title || tab.title || '网页 PDF').slice(0,160), kind: item.kind || 'PDF 链接' });
    if (candidates.length >= 60) break;
  }
  const current = httpURL(tab.url);
  if (current && !seen.has(current)) {
    const item = {url: current, title: String(tab.title || '网页 PDF').slice(0,160), kind: isPDFLink(current) ? '当前 PDF' : '当前页面 · 尝试识别 PDF'};
    if (isPDFLink(current)) candidates.unshift(item);
    else if (!candidates.length) candidates.push(item);
  }
  return candidates;
}
export function looksLikePDF(bytes) {
  return new TextDecoder('ascii').decode(bytes.subarray(0,1024)).includes('%PDF-');
}
export function toBase64(bytes) {
  let binary = '';
  for (let index=0; index<bytes.length; index+=8192) binary += String.fromCharCode(...bytes.subarray(index,index+8192));
  return btoa(binary);
}
