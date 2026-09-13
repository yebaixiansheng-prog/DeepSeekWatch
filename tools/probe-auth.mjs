// 探测：用非法 token 请求，观察服务端鉴权失败的响应形态
const UA = 'Mozilla/5.0 (Linux; HarmonyOS; HUAWEI WATCH) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36';

async function probe(url, opts) {
  try {
    const r = await fetch(url, opts);
    const text = await r.text();
    console.log('URL     :', url);
    console.log('STATUS  :', r.status, r.statusText);
    console.log('BODY    :', text.slice(0, 400));
    console.log('---');
    return { status: r.status, text };
  } catch (e) {
    console.log('URL     :', url);
    console.log('ERR     :', String(e));
    console.log('---');
  }
}

const base = 'https://chat.deepseek.com';
const H = { 'Content-Type': 'application/json', 'Accept': '*/*', 'User-Agent': UA };

// 1) 无 token 拉会话列表
await probe(base + '/api/v0/chat_session/fetch_page?lte_cursor.pinned=false&count=5', {
  method: 'GET', headers: H
});

// 2) 非法 token
await probe(base + '/api/v0/chat_session/fetch_page?lte_cursor.pinned=false&count=5', {
  method: 'GET', headers: { ...H, 'Authorization': 'Bearer INVALID_TOKEN_FOR_PROBE' }
});

// 3) 完全错误的路径，看 404 形态
await probe(base + '/api/v0/__not_exist__', { method: 'GET', headers: H });
