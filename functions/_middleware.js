const encoder = new TextEncoder();
const COOKIE_NAME = "__Host-lot_session";
const SESSION_SECONDS = 7 * 24 * 60 * 60;
const UPSTREAM_RAW = "https://raw.githubusercontent.com/akkk09/linuxontab/main";

function json(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), { status, headers: {
    "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff", ...headers
  }});
}
function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function fromBase64url(value) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
async function getSessionKey(secret) {
  return crypto.subtle.importKey("raw", encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}
async function createSession(secret) {
  const expires = Math.floor(Date.now() / 1000) + SESSION_SECONDS;
  const payload = encoder.encode("linuxontab-session-v1:" + expires);
  const key = await getSessionKey(secret);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, payload));
  return expires + "." + base64url(signature);
}
async function validSession(request, secret) {
  const cookie = request.headers.get("Cookie") || "";
  const entry = cookie.split(";").map((part) => part.trim())
    .find((part) => part.startsWith(COOKIE_NAME + "="));
  if (!entry) return false;
  const token = entry.slice(COOKIE_NAME.length + 1);
  const dot = token.indexOf(".");
  if (dot < 1) return false;
  const expires = Number(token.slice(0, dot));
  if (!Number.isSafeInteger(expires)) return false;
  const now = Math.floor(Date.now() / 1000);
  if (expires <= now || expires > now + SESSION_SECONDS) return false;
  try {
    const signature = fromBase64url(token.slice(dot + 1));
    const key = await getSessionKey(secret);
    return await crypto.subtle.verify("HMAC", key, signature,
      encoder.encode("linuxontab-session-v1:" + expires));
  } catch { return false; }
}
async function sha256(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}
function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
function originIsValid(request) {
  return request.headers.get("Origin") === new URL(request.url).origin;
}
function loginPage() {
  const html = [
    '<!doctype html>','<html lang="en">','<head>',
    '<meta charset="utf-8">','<meta name="viewport" content="width=device-width,initial-scale=1">',
    '<meta name="color-scheme" content="dark">','<title>LinuxOnTab · Sign in</title>',
    '<style>',
    ':root{color-scheme:dark;font-family:ui-sans-serif,system-ui,sans-serif;background:#090d12;color:#e7edf5}',
    '*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px}',
    'main{width:min(100%,390px);padding:32px;border:1px solid #263342;border-radius:18px;background:#101821;box-shadow:0 24px 80px #0008}',
    '.mark{display:grid;place-items:center;width:48px;height:48px;border-radius:14px;background:#1d2b3a;color:#8dc5ff;font-size:24px}',
    'h1{font-size:24px;margin:22px 0 6px}p{color:#9eacbb;line-height:1.5;margin:0 0 24px}',
    'label{display:block;font-size:13px;color:#c4d0dc;margin:16px 0 7px}',
    'input{width:100%;padding:12px 13px;border:1px solid #344456;border-radius:9px;background:#0a1119;color:#fff;font:inherit;outline:none}',
    'input:focus{border-color:#6ba9e8;box-shadow:0 0 0 3px #6ba9e822}',
    'button{width:100%;margin-top:22px;padding:12px;border:0;border-radius:9px;background:#8dc5ff;color:#07111d;font:600 15px inherit;cursor:pointer}',
    'button:disabled{opacity:.6;cursor:wait}#error{min-height:20px;margin:12px 0 0;color:#ff9d9d;font-size:13px}',
    'small{display:block;margin-top:18px;color:#6f8091;text-align:center}','</style>','</head>','<body>','<main>',
    '<div class="mark" aria-hidden="true">⌘</div>','<h1>LinuxOnTab</h1>',
    '<p>This instance is private. Sign in to open the Linux environment.</p>','<form id="login">',
    '<label for="username">Username</label>','<input id="username" name="username" autocomplete="username" required autofocus>',
    '<label for="password">Password</label>','<input id="password" name="password" type="password" autocomplete="current-password" required>',
    '<button id="submit" type="submit">Sign in</button>','<div id="error" role="alert" aria-live="polite"></div>',
    '</form>','<small>Protected access · Linux runs in your browser</small>','</main>','<script>',
    'const form=document.getElementById("login");const button=document.getElementById("submit");const error=document.getElementById("error");',
    'form.addEventListener("submit",async(event)=>{event.preventDefault();button.disabled=true;button.textContent="Checking…";error.textContent="";',
    'try{const body=new URLSearchParams(new FormData(form));const response=await fetch("/__auth/login",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/x-www-form-urlencoded"},body});',
    'if(!response.ok)throw new Error(response.status===401?"Incorrect username or password.":"Sign-in failed. Try again.");location.replace("/");',
    '}catch(err){error.textContent=err.message||"Could not sign in.";}finally{button.disabled=false;button.textContent="Sign in";}});',
    '</script>','</body>','</html>'
  ].join("\n");
  return new Response(html, { status: 200, headers: {
    "Content-Type":"text/html; charset=utf-8","Cache-Control":"no-store, private",
    "Content-Security-Policy":"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    "X-Content-Type-Options":"nosniff","X-Frame-Options":"DENY","Referrer-Policy":"no-referrer"
  }});
}
async function proxyLargeAsset(request, pathname) {
  const target = UPSTREAM_RAW + pathname;
  const headers = new Headers();
  for (const name of ["Range","If-Range","If-None-Match"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name,value);
  }
  const upstream = await fetch(target,{method:request.method,headers,redirect:"follow"});
  const responseHeaders = new Headers();
  for (const name of ["Content-Length","Content-Range","ETag","Last-Modified","Accept-Ranges"]) {
    const value=upstream.headers.get(name); if(value) responseHeaders.set(name,value);
  }
  responseHeaders.set("Content-Type",pathname.endsWith(".iso")?"application/octet-stream":(upstream.headers.get("Content-Type")||"application/octet-stream"));
  responseHeaders.set("Cache-Control","private, no-store");
  responseHeaders.set("X-Content-Type-Options","nosniff");
  return new Response(request.method==="HEAD"?null:upstream.body,{status:upstream.status,statusText:upstream.statusText,headers:responseHeaders});
}
export async function onRequest(context) {
  const {request,env}=context;
  const path=new URL(request.url).pathname;

  if(path==="/__auth/login") {
    if(request.method!=="POST") return json({error:"Method not allowed"},405,{Allow:"POST"});
    if(!originIsValid(request)) return json({error:"Invalid origin"},403);
    if(!env.AUTH_USERNAME||!env.AUTH_PASSWORD||!env.SESSION_SECRET||env.SESSION_SECRET.length<32)
      return json({error:"Authentication is not configured. Add AUTH_USERNAME, AUTH_PASSWORD and a 32+ character SESSION_SECRET in Cloudflare Pages settings."},503);
    const length=Number(request.headers.get("Content-Length")||"0");
    if(length>4096) return json({error:"Request too large"},413);
    let form;
    try {
      const bodyText=await request.text();
      if(new TextEncoder().encode(bodyText).byteLength>4096) return json({error:"Request too large"},413);
      form=new URLSearchParams(bodyText);
    }
    catch { return json({error:"Invalid request"},400); }
    const username=form.get("username")||"";
    const password=form.get("password")||"";
    if(username.length>128||password.length>1024) return json({error:"Invalid credentials"},401);
    const [givenUser,wantedUser,givenPassword,wantedPassword]=await Promise.all([
      sha256(username),sha256(env.AUTH_USERNAME),sha256(password),sha256(env.AUTH_PASSWORD)
    ]);
    const userMatches=constantTimeEqual(givenUser,wantedUser);
    const passwordMatches=constantTimeEqual(givenPassword,wantedPassword);
    if(!(userMatches&&passwordMatches)) return json({error:"Invalid credentials"},401);
    const token=await createSession(env.SESSION_SECRET);
    return json({ok:true},200,{"Set-Cookie":COOKIE_NAME+"="+token+"; Path=/; Max-Age="+SESSION_SECONDS+"; Secure; HttpOnly; SameSite=Strict"});
  }

  if(path==="/__auth/logout") {
    if(request.method!=="POST") return json({error:"Method not allowed"},405,{Allow:"POST"});
    if(!originIsValid(request)) return json({error:"Invalid origin"},403);
    return new Response(null,{status:303,headers:{
      "Location":"/","Set-Cookie":COOKIE_NAME+"=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict","Cache-Control":"no-store"
    }});
  }

  if(!env.AUTH_USERNAME||!env.AUTH_PASSWORD||!env.SESSION_SECRET||env.SESSION_SECRET.length<32)
    return new Response("Authentication is not configured.",{status:503,headers:{"Content-Type":"text/plain; charset=utf-8","Cache-Control":"no-store"}});

  if(!(await validSession(request,env.SESSION_SECRET))) {
    const acceptsHtml=(request.headers.get("Accept")||"").includes("text/html");
    if(acceptsHtml||path.endsWith("/")||path.endsWith(".html")) return loginPage();
    return new Response("Authentication required.",{status:401,headers:{"Content-Type":"text/plain; charset=utf-8","Cache-Control":"no-store"}});
  }

  if(request.method==="GET"||request.method==="HEAD") {
    if(path==="/shell/alpine.iso"||(path.startsWith("/packages/")&&path!=="/packages/"&&path!=="/packages/index.html"))
      return proxyLargeAsset(request,path);
  }

  const response=await context.next();
  const responseHeaders=new Headers(response.headers);
  responseHeaders.set("X-Content-Type-Options","nosniff");
  responseHeaders.set("Referrer-Policy","strict-origin-when-cross-origin");
  return new Response(response.body,{status:response.status,statusText:response.statusText,headers:responseHeaders});
}
