#!/bin/bash
# Starts the hermes gateway (background) and dashboard (foreground).
#
# Gateway (port 8642): handles tool execution, SSH connections, model calls.
# Dashboard (port 18789): web UI — nginx proxies this through the Docker network.
#
# --insecure is safe here: 172.28.0.10:18789 is only reachable within the
# agent-dev-net Docker bridge. nginx (172.28.0.20) adds basic auth on top.
# Nothing external can reach the container IP directly.

HERMES=/opt/hermes/.venv/bin/hermes

$HERMES gateway run &
GATEWAY_PID=$!

GATEWAY_HEALTH_URL=http://127.0.0.1:8642 \
    $HERMES dashboard --port 18789 --host 0.0.0.0 --no-open --insecure

echo ""
echo "[INFO] Hermes exited — container staying alive for manual setup."
echo "[INFO] Run:  docker exec -it -u hermes agent-dev bash"
echo "[INFO] Then: hermes setup"

# Keep container alive so operator can exec in and configure
wait $GATEWAY_PID 2>/dev/null
exec sleep infinity
