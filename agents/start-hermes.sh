#!/bin/bash
# Wrapper that keeps the container alive if hermes exits (e.g. not yet configured).
# This lets the operator exec in and run 'hermes setup' without the container
# restarting in a loop.
/opt/hermes/.venv/bin/hermes "$@"
echo ""
echo "[INFO] Hermes exited — container staying alive for manual setup."
echo "[INFO] Run:  docker exec -it agent-dev bash"
echo "[INFO] Then: hermes setup"
exec sleep infinity
