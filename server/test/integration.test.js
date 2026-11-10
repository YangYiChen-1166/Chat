import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Miniflare } from 'miniflare';

const mf = new Miniflare({ modules: true, scriptPath: './src/index.js', compatibilityDate: '2026-07-30', d1Databases:['DB'], r2Buckets:['MEDIA'] });
after(() => mf.dispose());
test('registration, friends, text, media and access control', async () => {
  const db = await mf.getD1Database('DB');
  const migration = await readFile('./migrations/0001_initial.sql', 'utf8');
  await db.batch(migration.split(';').map(s => s.trim()).filter(Boolean).map(s => db.prepare(s)));
  const call = async (path, method='GET', data, token, type='application/json') => {
    const h = {'CF-Connecting-IP':'127.0.0.1'};
    if(token) h.Authorization = `Bearer ${token}`;
    if(data !== undefined) h['Content-Type']=type;
    const response=await mf.dispatchFetch('https://example.test'+path,{method,headers:h,body:data === undefined ? undefined : type === 'application/json' ? JSON.stringify(data) : data});
    const bytes = new Uint8Array(await response.arrayBuffer());
    const value = response.headers.get('content-type')?.includes('json') ? JSON.parse(new TextDecoder().decode(bytes)) : bytes;
    return {status:response.status,value};
  };
  const register = async username => { const r=await call('/register','POST',{username,password:'correct horse battery staple'}); assert.equal(r.status,201,JSON.stringify(r.value)); return r.value; };
  const alice=await register('alice'), bob=await register('bob'), eve=await register('eve');
  assert.equal((await call('/login','POST',{username:'alice',password:'incorrectpassword'})).status,401);
  assert.equal((await call('/messages/'+bob.user.id,'GET',undefined,alice.token)).status,403);
  assert.equal((await call('/friends/request','POST',{username:'bob'},alice.token)).status,200);
  let b=await call('/friends','GET',undefined,bob.token); assert.equal(b.value.requests[0].id,alice.user.id);
  assert.equal((await call('/friends/'+alice.user.id+'/accept','POST',{},bob.token)).status,200);
  const sent=await call('/messages/'+bob.user.id,'POST',{text:'你好'},alice.token); assert.equal(sent.status,201);
  const messages=await call('/messages/'+alice.user.id,'GET',undefined,bob.token); assert.equal(messages.value.messages[0].body,'你好');
  const upload=await call('/media/'+bob.user.id+'/image','POST',new Uint8Array([1,2,3]),alice.token,'image/jpeg'); assert.equal(upload.status,201,JSON.stringify(upload.value));
  const media=await call('/media/'+upload.value.id,'GET',undefined,bob.token); assert.deepEqual([...media.value],[1,2,3]);
  const voice=await call('/media/'+bob.user.id+'/audio','POST',new Uint8Array([4,5,6]),alice.token,'audio/mp4'); assert.equal(voice.status,201);
  const voiceData=await call('/media/'+voice.value.id,'GET',undefined,bob.token); assert.deepEqual([...voiceData.value],[4,5,6]);
  assert.equal((await call('/media/'+bob.user.id+'/image','POST',new Uint8Array([1]),alice.token,'text/plain')).status,415);
  assert.equal((await call('/messages/'+bob.user.id,'POST',{text:'x'.repeat(4001)},alice.token)).status,400);
  assert.equal((await call('/media/'+upload.value.id,'GET',undefined,eve.token)).status,404);
  assert.equal((await call('/messages/'+bob.user.id,'GET',undefined,eve.token)).status,403);
  assert.equal((await call('/logout','POST',{},alice.token)).status,200);
  assert.equal((await call('/me','GET',undefined,alice.token)).status,401);
});



