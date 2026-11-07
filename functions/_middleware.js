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
function fromHex(value) {
  if (!/^[0-9a-f]{32,128}$/i.test(value) || value.length % 2 !== 0) return null;
  const bytes = new Uint8Array(value.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(value.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}
async function verifyPassword(password, encodedHash) {
  // Cloudflare secrets can accidentally include copied whitespace/newlines.
  // The hash format itself contains no whitespace, so normalize it before parsing.
  encodedHash = String(encodedHash || "").trim();
  // Format: pbkdf2-sha256$iterations$salt-hex$derived-key-hex
  const parts = encodedHash.split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2-sha256") return false;
  const iterations = Number(parts[1]);
  const salt = fromHex(parts[2]);
  const expected = fromHex(parts[3]);
  if (!Number.isSafeInteger(iterations) || iterations < 100000 || iterations > 600000 ||
      !salt || salt.length < 16 || !expected || expected.length !== 32) return false;
  try {
    const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
    const derived = new Uint8Array(await crypto.subtle.deriveBits(
      { name: "PBKDF2", salt, iterations, hash: "SHA-256" }, key, 256
    ));
    return constantTimeEqual(derived, expected);
  } catch { return false; }
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
    if(!env.AUTH_USERNAME||!env.AUTH_PASSWORD_HASH||!env.SESSION_SECRET||env.SESSION_SECRET.length<32)
      return json({error:"Authentication is not configured. Add AUTH_USERNAME, AUTH_PASSWORD_HASH and a 32+ character SESSION_SECRET in Cloudflare Pages settings."},503);
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
    const [givenUser,wantedUser,passwordMatches]=await Promise.all([
      crypto.subtle.digest("SHA-256",encoder.encode(username)),
      crypto.subtle.digest("SHA-256",encoder.encode(env.AUTH_USERNAME)),
      verifyPassword(password,env.AUTH_PASSWORD_HASH)
    ]);
    const userMatches=constantTimeEqual(new Uint8Array(givenUser),new Uint8Array(wantedUser));
    if(!(userMatches&&passwordMatches)) {
      // Temporary diagnostics: booleans only; never log credential material.
      console.log("LinuxOnTab auth check failed", {
        usernameConfigured: typeof env.AUTH_USERNAME === "string" && env.AUTH_USERNAME.length > 0,
        hashConfigured: typeof env.AUTH_PASSWORD_HASH === "string" && env.AUTH_PASSWORD_HASH.length > 0,
        hashPrefixValid: String(env.AUTH_PASSWORD_HASH || "").trim().startsWith("pbkdf2-sha256$"),
        usernameMatches: userMatches,
        passwordMatches
      });
      return json({error:"Invalid credentials"},401);
    }
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

  if(!env.AUTH_USERNAME||!env.AUTH_PASSWORD_HASH||!env.SESSION_SECRET||env.SESSION_SECRET.length<32)
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
