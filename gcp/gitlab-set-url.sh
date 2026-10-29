#!/bin/sh
# Run on gitlab-1 (29/10): GitLab is reached as https://gitlab.talos.internal (Traefik in the
# cluster terminates TLS, host2 SSH tunnel -> 127.0.0.1:18081). nginx keeps plain HTTP on 18081,
# Let's Encrypt stays off (the name only exists in the office LAN), SAML ACS follows the new URL.
# Backup: /etc/gitlab/gitlab.rb.bak-20261029. Then: sudo gitlab-ctl reconfigure
set -eu
f=/etc/gitlab/gitlab.rb
[ -f $f.bak-20261029 ] || cp $f $f.bak-20261029
sed -i "s#^external_url .*#external_url 'https://gitlab.talos.internal'#" $f
sed -i "s#assertion_consumer_service_url: 'http://localhost:18081/#assertion_consumer_service_url: 'https://gitlab.talos.internal/#" $f
grep -q "^nginx\['listen_port'\]" $f || echo "nginx['listen_port'] = 18081" >> $f
grep -q "^nginx\['listen_https'\]" $f || echo "nginx['listen_https'] = false" >> $f
grep -q "^letsencrypt\['enable'\]" $f || echo "letsencrypt['enable'] = false" >> $f
grep -nE "^external_url|^nginx\[|^letsencrypt|assertion_consumer_service_url" $f
