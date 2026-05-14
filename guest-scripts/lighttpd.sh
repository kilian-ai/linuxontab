#mkdir -p /tmp/www && echo '<h1>Hello from v86 Alpine guest!</h1>' > /tmp/www/index.html
printf 'server.document-root="/tmp/www"\nserver.port=8080\nserver.bind="0.0.0.0"\nserver.username=""\nserver.groupname=""\nindex-file.names=("index.html")\n' > /tmp/lighttpd.conf
lighttpd -f /tmp/lighttpd.conf && echo "lighttpd OK"