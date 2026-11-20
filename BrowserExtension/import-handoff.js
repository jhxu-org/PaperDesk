import {httpURL} from './pdf-utils.js';

const PREFIX = 'pendingImport:';
const LIFETIME = 5 * 60 * 1000;
const validID = value => /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value || '');

// Signed download URLs belong in memory, never in extension-page URLs/history.
export async function createHandoff(storage, url, title, now = Date.now()) {
  const safeURL = httpURL(url);
  if (!safeURL) throw new Error('无效的 PDF 链接。');
  const records = Object.entries(await storage.get(null)).filter(([key]) => key.startsWith(PREFIX));
  const alive = records.filter(([, value]) => value && now - value.createdAt >= 0 && now - value.createdAt < LIFETIME)
    .sort((a, b) => b[1].createdAt - a[1].createdAt).slice(0, 19);
  const retained = new Set(alive.map(([key]) => key));
  await storage.remove(records.filter(([key]) => !retained.has(key)).map(([key]) => key));
  const id = crypto.randomUUID();
  await storage.set({[PREFIX + id]: {url: safeURL, title: String(title || '网页 PDF').slice(0, 160), createdAt: now}});
  return id;
}

export async function consumeHandoff(storage, id, now = Date.now()) {
  if (!validID(id)) return null;
  const key = PREFIX + id;
  const value = (await storage.get(key))[key];
  await storage.remove(key);
  if (!value || !(now - value.createdAt >= 0 && now - value.createdAt < LIFETIME) || !httpURL(value.url)) return null;
  return {url: httpURL(value.url), title: String(value.title || '网页 PDF').slice(0, 160)};
}
