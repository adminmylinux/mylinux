#!/bin/sh
# Deploy web/ to contabogit: /opt/mylinux-web/app (source) + docker compose.
# Secrets stay in /opt/mylinux-web/.env on the server (see .env.example).
set -e
cd "$(dirname "$0")"
HOST=${HOST:-contabogit}
rsync -az --delete --exclude node_modules --exclude dist --exclude .env --exclude server.log ./ "$HOST":/opt/mylinux-web/app/
ssh "$HOST" 'set -e; cd /opt/mylinux-web; cp app/docker-compose.yml docker-compose.yml;
  [ -f .env ] || { echo "missing /opt/mylinux-web/.env, copy app/.env.example and fill it in"; exit 1; }
  docker compose up -d --build 2>&1 | tail -3; sleep 3
  docker compose ps --format "table {{.Name}}\t{{.Status}}"
  curl -s http://127.0.0.1:8801/api/config; echo'
