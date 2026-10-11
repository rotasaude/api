#!/usr/bin/env bash
# Prova descartável do snippet nginx-city.conf.example: sobe um backend que ecoa
# os cabeçalhos e o proxy com o snippet, faz as requisições e mostra o access log.
# Uso: config/edge-proxy/prove.sh   (precisa de docker; nada fica de pé no fim)
set -euo pipefail
cd "$(dirname "$0")"
IMG=mirror.gcr.io/library/nginx:alpine   # Docker Hub anônimo falha; usar o espelho
NET=fix62-net; BE=fix62-backend; PX=fix62-proxy
T=""
cleanup() { docker rm -f $PX $BE >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; rm -rf "${T:-}"; }
trap cleanup EXIT
cleanup; T=$(mktemp -d)   # limpa sobras de execução anterior e só então cria o temporário

# Backend fake: ecoa XFF e X-Real-IP na resposta.
cat > "$T/backend.conf" <<'CONF'
server { listen 80; location / {
  add_header Content-Type text/plain;
  return 200 "got XFF=[$http_x_forwarded_for] XRI=[$http_x_real_ip] Host=[$http_host] Proto=[$http_x_forwarded_proto]\n"; } }
CONF
# Adapta o snippet para o teste: troca só o upstream.
sed 's#kamal-proxy.interno:80#fix62-backend:80#' nginx-city.conf.example > "$T/city.conf"
printf 'events {}\nhttp { include /etc/nginx/city.conf; }\n' > "$T/nginx.conf"

docker network create $NET >/dev/null
docker run -d --name $BE --network $NET -v "$T/backend.conf:/etc/nginx/conf.d/default.conf:ro" $IMG >/dev/null
echo "== nginx -t"; docker run --rm --network $NET --add-host fix62-backend:127.0.0.1 \
  -v "$T/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$T/city.conf:/etc/nginx/city.conf:ro" $IMG nginx -t 2>&1
docker run -d --name $PX --network $NET -v "$T/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$T/city.conf:/etc/nginx/city.conf:ro" $IMG >/dev/null
sleep 1
for p in /v/abc123token /v/abc123token/signed.pdf?x=1 /r/abc123token /r/abc123token?k=abc123token /v/lookup /v/lookup?cpf=1 \
         /v//abc123token //v/abc123token /v/abc123token/ /v//abc123token//signed.pdf /%76/abc123token /%72/abc123token \
         /%56/abc123token /%52//abc123token /v%2Fabc123token //v//lookup /%76/lookup; do
  echo "== GET $p"
  docker exec $PX wget -qO- --header='X-Forwarded-For: 6.6.6.6' --header='Referer: http://x/v/abc123token' "http://127.0.0.1$p"
done
echo "== access log"; docker logs $PX 2>&1 | grep -E '"(GET|POST)' || true
echo "== vazamento (esperado 0):"; docker logs $PX 2>&1 | grep -c abc123token || true
