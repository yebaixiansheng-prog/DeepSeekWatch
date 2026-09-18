// 探测：用非法 token 请求，观察服务端鉴权失败的响应形态
// ★ UA 必须与 App 的 Constants.ets 一致，否则探到的响应形态不代表 App 会遇到什么
const UA = 'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const PLATFORM = 'web';   // 与 Constants.ets 的 DsDevice.PLATFORM 一致

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
const H = {
  'Content-Type': 'application/json',
  'Accept': '*/*',
  'User-Agent': UA,
  'x-ds-platform': PLATFORM,
};

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
