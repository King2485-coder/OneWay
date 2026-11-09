import test from 'node:test';
import assert from 'node:assert/strict';
import { z } from 'zod';
import { partialUpdateSchema } from '../src/lib/patchSchema';

test('partial updates preserve omitted create defaults and explicit values', () => {
  const create = z.object({ title: z.string().trim().min(1), visible: z.boolean().default(true), count: z.number().int().nonnegative().default(0), tags: z.array(z.string()).default([]) });
  const patch = partialUpdateSchema(create);
  assert.deepEqual(patch.parse({}), {});
  assert.deepEqual(patch.parse({title:' renamed '}), {title:'renamed'});
  assert.deepEqual(patch.parse({visible:false,count:2,tags:[]}), {visible:false,count:2,tags:[]});
  assert.deepEqual(patch.parse({count:undefined}), {count:undefined});
  assert.equal(patch.safeParse({count:-1}).success, false);
  assert.equal(patch.safeParse(null).success, false);
  assert.deepEqual(patch.parse({unknown:'discard'}), {});
  assert.deepEqual(create.parse({title:'new'}), {title:'new',visible:true,count:0,tags:[]});
});
test('oversized constrained collections reject before invoking item validation', () => {
  let visited = 0;
  const schema = z.array(z.string().superRefine(() => { visited++; })).max(80);
  assert.equal(schema.safeParse(Array(100000).fill('item')).success, false);
  assert.equal(visited, 0);
});
test('record validation retains string-key value constraints', () => {
  const schema = z.record(z.string(), z.union([z.string(),z.boolean(),z.number()]));
  assert.deepEqual(schema.parse({private:true,label:'me',limit:1}), {private:true,label:'me',limit:1});
  assert.equal(schema.safeParse({private:{nested:true}}).success, false);
});

test('compressed request with trailing garbage does not crash the server', async () => {
  const { spawnSync } = await import('node:child_process');
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import express from 'express';
    import http from 'node:http';
    import { gzipSync } from 'node:zlib';
    const app = express();
    app.use(express.json());
    app.post('/', (_req,res) => res.sendStatus(204));
    app.use((err,req,res,next) => res.sendStatus(400));
    const server = app.listen(0,'127.0.0.1', () => {
      const payload = Buffer.concat([gzipSync(Buffer.from('{}')),Buffer.from('invalid trailing frame')]);
      const req = http.request({host:'127.0.0.1',port:server.address().port,path:'/',method:'POST',headers:{'content-type':'application/json','content-encoding':'gzip','content-length':payload.length}}, res => {
        res.resume();
        res.on('end', () => setTimeout(() => server.close(),100));
      });
      req.on('error', () => process.exit(2));
      req.end(payload);
    });
  `], {timeout:5000, encoding:'utf8'});
  assert.equal(child.error, undefined);
  assert.equal(child.status, 0, child.stderr);
});
