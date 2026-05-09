(function(){
  // Replace CODE and DEV_PORT before using
  const CODE = 'ABCD';
  const DEV_PORT = 3000;
  const PATH = '/bundle.js';
  const url = `https://linuxontab-tunnel.fly.dev/port/http/${CODE}/${DEV_PORT}${PATH}`;
  const s = document.createElement('script');
  s.src = url;
  s.async = true;
  document.head.appendChild(s);

  // Dev ws reload listener
  try {
    const wsUrl = `wss://linuxontab-tunnel.fly.dev/port/client?code=${CODE}&port=${DEV_PORT}&path=/ws`;
    const ws = new WebSocket(wsUrl);
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        console.log('dev change', msg);
        // naive reload on JS change
        if (msg && msg.path && msg.path.endsWith('.js')) location.reload();
      } catch (e) { console.log('ws parse err', e); }
    };
  } catch (e) { console.log('dev-ws not available', e); }
})();
