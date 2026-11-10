const MAX_MEDIA = 10 * 1024 * 1024;
const USERNAME = /^[a-zA-Z0-9_]{3,24}$/;
const enc = new TextEncoder();
const json = (value, status = 200) => Response.json(value, {status, headers: {'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff'}});
const fail = (message, status = 400) => { throw new HttpError(message, status); };
class HttpError extends Error { constructor(message, status) { super(message); this.status = status; } }
const hex = bytes => Array.from(new Uint8Array(bytes), x => x.toString(16).padStart(2,'0')).join('');
const random = n => hex(crypto.getRandomValues(new Uint8Array(n)));
const hash = async value => hex(await crypto.subtle.digest('SHA-256', enc.encode(value)));
async function passwordHash(password, salt) {
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  return hex(await crypto.subtle.deriveBits({name:'PBKDF2', hash:'SHA-256', salt:enc.encode(salt), iterations:100000}, key, 256));
}
async function constantEqual(a,b) {
  const key = await crypto.subtle.importKey('raw', enc.encode('chat-password-comparison'), {name:'HMAC', hash:'SHA-256'}, false, ['sign','verify']);
  const signature = await crypto.subtle.sign('HMAC', key, enc.encode(a));
  return crypto.subtle.verify('HMAC', key, signature, enc.encode(b));
}
async function body(req) {
  if (Number(req.headers.get('content-length') || 0) > 16384) fail('请求过大', 413);
  if (!req.body) fail('请求格式错误');
  const reader = req.body.getReader(), chunks = []; let size = 0;
  for (;;) {
    const {done, value} = await reader.read(); if (done) break;
    size += value.byteLength;
    if (size > 16384) { await reader.cancel(); fail('请求过大', 413); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const text = new TextDecoder().decode(bytes);
  try { const value = JSON.parse(text); if (!value || typeof value !== 'object' || Array.isArray(value)) throw 0; return value; }
  catch { fail('请求格式错误'); }
}
async function limit(env, key, max, windowSeconds) {
  const now = Math.floor(Date.now()/1000), slot = Math.floor(now/windowSeconds);
  const k = await hash(key + ':' + slot);
  const row = await env.DB.prepare('INSERT INTO rate_limits (key, count, expires_at) VALUES (?, 1, ?) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count').bind(k, (slot+2)*windowSeconds).first();
  if (row.count === 1) await env.DB.prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(now).run();
  if (row.count > max) fail('操作过于频繁，请稍后再试', 429);
}
async function authenticate(req, env) {
  const token = (req.headers.get('authorization') || '').match(/^Bearer ([a-f0-9]{64})$/)?.[1];
  if (!token) fail('请先登录', 401);
  const user = await env.DB.prepare('SELECT u.id,u.username FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at>?').bind(await hash(token), Date.now()).first();
  if (!user) fail('登录已失效，请重新登录',401);
  return { ...user, token };
}
async function issueSession(env, user) {
  const token = random(32);
  await env.DB.prepare('INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)').bind(await hash(token),user.id,Date.now()+30*86400000).run();
  return {token, user:{id:user.id,username:user.username}};
}
async function friend(env, a, b) {
  const [low, high] = [a,b].sort();
  return !!(await env.DB.prepare('SELECT 1 FROM friendships WHERE user_low=? AND user_high=?').bind(low,high).first());
}
function validId(id) { return /^[0-9a-f-]{36}$/.test(id || ''); }
async function route(req, env) {
  const url = new URL(req.url), path = url.pathname, method = req.method;
  if (path === '/health' && method === 'GET') return json({ok:true});
  if ((path === '/register' || path === '/login') && method === 'POST') {
    const ip = req.headers.get('CF-Connecting-IP') || 'unknown';
    await limit(env, 'auth:'+ip, 30, 900);
    const input = await body(req), username = typeof input.username === 'string' ? input.username.trim() : '', password = input.password;
    if (!USERNAME.test(username) || typeof password !== 'string' || password.length < 10 || password.length > 128) fail('用户名需为 3–24 位字母、数字或下划线；密码需为 10–128 位');
    await limit(env, 'auth-user:'+username.toLowerCase(), 20, 900);
    if (path === '/register') {
      const salt=random(16), id=crypto.randomUUID(), digest=await passwordHash(password,salt);
      try { await env.DB.prepare('INSERT INTO users(id,username,password_hash,password_salt,created_at) VALUES(?,?,?,?,?)').bind(id,username,digest,salt,Date.now()).run(); }
      catch(e) { if (String(e).includes('UNIQUE constraint failed')) fail('用户名已被使用',409); throw e; }
      return json(await issueSession(env,{id,username}),201);
    }
    const user=await env.DB.prepare('SELECT id,username,password_hash,password_salt FROM users WHERE username=? COLLATE NOCASE').bind(username).first();
    const calculated=await passwordHash(password,user?.password_salt || '00000000000000000000000000000000');
    if (!user || !(await constantEqual(user.password_hash,calculated))) fail('用户名或密码不正确',401);
    return json(await issueSession(env,user));
  }
  const me=await authenticate(req,env);
  if (path === '/me' && method === 'GET') return json({id:me.id,username:me.username});
  if (path === '/logout' && method === 'POST') { await env.DB.prepare('DELETE FROM sessions WHERE token_hash=?').bind(await hash(me.token)).run(); return json({ok:true}); }
  if (path === '/friends' && method === 'GET') {
    const friends=await env.DB.prepare('SELECT u.id,u.username FROM friendships f JOIN users u ON u.id=CASE WHEN f.user_low=? THEN f.user_high ELSE f.user_low END WHERE f.user_low=? OR f.user_high=? ORDER BY u.username').bind(me.id,me.id,me.id).all();
    const requests=await env.DB.prepare('SELECT u.id,u.username FROM friend_requests r JOIN users u ON u.id=r.sender_id WHERE r.recipient_id=? ORDER BY r.created_at DESC').bind(me.id).all();
    return json({friends:friends.results,requests:requests.results});
  }
  if (path === '/friends/request' && method === 'POST') {
    await limit(env,'request:'+me.id,30,3600);
    const {username}=await body(req);
    if (typeof username !== 'string' || !USERNAME.test(username)) fail('请输入有效用户名');
    const target=await env.DB.prepare('SELECT id,username FROM users WHERE username=? COLLATE NOCASE').bind(username).first();
    if (!target || target.id === me.id) fail('无法向此用户发送申请',404);
    if (await friend(env,me.id,target.id)) fail('你们已经是好友',409);
    const reciprocal=await env.DB.prepare('SELECT 1 FROM friend_requests WHERE sender_id=? AND recipient_id=?').bind(target.id,me.id).first();
    if (reciprocal) { await accept(env,me.id,target.id); return json({accepted:true}); }
    await env.DB.prepare('INSERT OR IGNORE INTO friend_requests(sender_id,recipient_id,created_at) VALUES(?,?,?)').bind(me.id,target.id,Date.now()).run();
    return json({ok:true});
  }
  const acceptMatch=path.match(/^\/friends\/([0-9a-f-]+)\/accept$/);
  if (acceptMatch && method === 'POST') { const other=acceptMatch[1]; if (!validId(other)) fail('请求无效'); await accept(env,me.id,other); return json({ok:true}); }
  const msgMatch=path.match(/^\/messages\/([0-9a-f-]+)$/);
  if (msgMatch && validId(msgMatch[1])) {
    const other=msgMatch[1]; if (!(await friend(env,me.id,other))) fail('只能与好友聊天',403);
    if (method==='GET') {
      const rows=await env.DB.prepare('SELECT id,sender_id,recipient_id,kind,body,created_at FROM messages WHERE (sender_id=? AND recipient_id=?) OR (sender_id=? AND recipient_id=?) ORDER BY created_at DESC,id DESC LIMIT 200').bind(me.id,other,other,me.id).all();
      return json({messages:rows.results.reverse()});
    }
    if (method==='POST') {
      await limit(env,'message:'+me.id,240,60);
      const {text}=await body(req); if (typeof text !== 'string' || !text.trim() || text.length>4000) fail('消息长度需为 1–4000 字');
      const m={id:crypto.randomUUID(),sender_id:me.id,recipient_id:other,kind:'text',body:text.trim(),created_at:Date.now()};
      await env.DB.prepare('INSERT INTO messages(id,sender_id,recipient_id,kind,body,created_at) VALUES(?,?,?,?,?,?)').bind(m.id,m.sender_id,m.recipient_id,m.kind,m.body,m.created_at).run(); return json(m,201);
    }
  }
  const upload=path.match(/^\/media\/([0-9a-f-]+)\/(image|audio)$/);
  if (upload && method==='POST') {
    const other=upload[1],kind=upload[2]; if (!validId(other) || !(await friend(env,me.id,other))) fail('只能向好友发送附件',403);
    await limit(env,'media:'+me.id,30,60);
    const type=(req.headers.get('content-type')||'').split(';')[0];
    if (!(kind==='image' ? ['image/jpeg','image/png','image/heic'] : ['audio/mp4','audio/x-m4a','audio/m4a']).includes(type)) fail('不支持的附件格式',415);
    const declared=Number(req.headers.get('content-length')||0); if (declared>MAX_MEDIA) fail('附件不能超过 10 MB',413);
    if (!req.body) fail('附件为空');
    const reader=req.body.getReader(), chunks=[]; let size=0;
    for (;;) { const {done,value}=await reader.read(); if(done) break; size+=value.byteLength; if(size>MAX_MEDIA) { await reader.cancel(); fail('附件不能超过 10 MB',413); } chunks.push(value); }
    if (!size) fail('附件为空');
    const data=new Uint8Array(size); let offset=0; for(const chunk of chunks){data.set(chunk,offset);offset+=chunk.length;}
    const id=crypto.randomUUID(),key='media/'+random(24),created=Date.now();
    await env.MEDIA.put(key,data,{httpMetadata:{contentType:type}});
    try { await env.DB.prepare('INSERT INTO messages(id,sender_id,recipient_id,kind,object_key,created_at) VALUES(?,?,?,?,?,?)').bind(id,me.id,other,kind,key,created).run(); }
    catch(e) { await env.MEDIA.delete(key); throw e; }
    return json({id,sender_id:me.id,recipient_id:other,kind,body:null,created_at:created},201);
  }
  const download=path.match(/^\/media\/([0-9a-f-]+)$/);
  if (download && method==='GET' && validId(download[1])) {
    const m=await env.DB.prepare('SELECT object_key FROM messages WHERE id=? AND (sender_id=? OR recipient_id=?) AND object_key IS NOT NULL').bind(download[1],me.id,me.id).first();
    if (!m) fail('附件不存在',404);
    const object=await env.MEDIA.get(m.object_key); if(!object) fail('附件不存在',404);
    return new Response(object.body,{headers:{'Content-Type':object.httpMetadata?.contentType||'application/octet-stream','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'}});
  }
  fail('接口不存在',404);
}
async function accept(env, me, other) {
  const pending=await env.DB.prepare('SELECT 1 FROM friend_requests WHERE sender_id=? AND recipient_id=?').bind(other,me).first();
  if(!pending) fail('好友申请不存在',404);
  const [low,high]=[me,other].sort();
  await env.DB.batch([
    env.DB.prepare('INSERT OR IGNORE INTO friendships(user_low,user_high,created_at) VALUES(?,?,?)').bind(low,high,Date.now()),
    env.DB.prepare('DELETE FROM friend_requests WHERE (sender_id=? AND recipient_id=?) OR (sender_id=? AND recipient_id=?)').bind(me,other,other,me)
  ]);
}
export default { async fetch(req,env) { try { return await route(req,env); } catch(e) { if(e instanceof HttpError) return json({error:e.message},e.status); console.error(JSON.stringify({event:'request_failed',message:String(e)})); return json({error:'服务暂时不可用'},500); } } };


