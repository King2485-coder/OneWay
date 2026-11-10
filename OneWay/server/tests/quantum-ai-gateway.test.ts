import test from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { quantumAIGatewayRouter } from "../src/routes/quantumAIGateway";

test("AI gateway rejects impersonation and stale origins, and forwards only the verified account", async () => {
  let now = 1; const secret = "a".repeat(64); const calls: any[] = [];
  const app = express(); app.use(express.json());
  app.use("/ai", quantumAIGatewayRouter({ secret, clock: () => now,
    authenticate: (req, res, next) => { if (req.header("authorization") !== "Bearer real-session") { res.status(401).end(); return; } (req as any).userId = "verified-account"; next(); },
    forward: (async (url: string, options: any) => { calls.push({url, options}); return new Response(JSON.stringify({available:true}), {headers:{"content-type":"application/json"}}); }) as any,
  }));
  const server = app.listen(0,"127.0.0.1"); await new Promise<void>(r => server.on("listening",r)); const base=`http://127.0.0.1:${(server.address() as any).port}/ai`;
  async function register(origin: string, authorization = "Bearer " + secret) { return fetch(base+"/gateway-register",{method:"POST",headers:{authorization,"content-type":"application/json"},body:JSON.stringify({origin})}); }
  try {
    assert.equal((await fetch(base+"/config",{headers:{authorization:"Bearer dev:someone","x-dev-user-id":"someone"}})).status,401);
    assert.equal((await register("https://test.trycloudflare.com","Bearer wrong")).status,401);
    assert.equal((await register("http://127.0.0.1:11434")).status,400);
    assert.equal((await register("https://test.trycloudflare.com.attacker.test")).status,400);
    assert.equal((await register("https://test.trycloudflare.com")).status,204);
    const result=await fetch(base+"/config",{headers:{authorization:"Bearer real-session","x-oneway-gateway-user":"attacker"}});
    assert.equal(result.status,200); assert.equal(calls[0].options.headers['x-oneway-gateway-user'],"verified-account"); assert.equal(calls[0].options.headers.Authorization,"Bearer "+secret);
    assert.equal((await fetch(base+"/../../api/auth/me",{headers:{authorization:"Bearer real-session"}})).status,404);
    now+=120001; assert.equal((await fetch(base+"/config",{headers:{authorization:"Bearer real-session"}})).status,503);
  } finally {server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));}
});
