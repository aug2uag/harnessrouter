#!/usr/bin/env bash
# Start the two processes and keep them honest.
#
# If either one dies the container exits, rather than limping along answering for a backend
# that's gone — a half-dead container that still passes a TCP check is worse than one that
# restarts. `docker run --restart` then does the recovering.
set -euo pipefail

# ── privilege layout ──────────────────────────────────────────────────────────
# Three principals, and the distance between them is the product's security model:
#   root    this entrypoint and the runner. The runner switches to a per-session uid for every
#           agent process, which is the one thing that needs root. CAP_SETUID, CAP_SETGID and
#           CAP_CHOWN are in Docker's default set: no --privileged, no --cap-add.
#   agent   the product: the gateway, the data volume. Its databases, blobs and secret store
#           are readable by it alone.
#   20000+  one uid per session, owning its session directory and nothing else. It cannot read or
#           write another session's workspace, the workspace parent, the databases, the blobs or
#           the secret store: a deliverable written to any of those paths fails at the write, while
#           the model is still there to choose the right one, instead of vanishing. Shared scratch
#           (/tmp, /var/tmp, /dev/shm) stays writable, because tools hardcode it — see the mode
#           below. See _isolate_session in runner/server.py.
if [ "$(id -u)" -ne 0 ]; then
  echo "[harnessrouter] ERROR: the container must start as root. It drops privileges itself: the product runs as 'agent', every agent process as its own session uid. Remove --user from docker run."
  exit 1
fi
PRODUCT=agent
AS_PRODUCT="setpriv --reuid=$PRODUCT --regid=$PRODUCT --init-groups"

DATA_DIR="${HR_DATA_DIR:-/data}"
mkdir -p "$DATA_DIR"

# Session workspaces live on the volume so a restart doesn't discard work in flight. Created HERE
# rather than in the image: /data is a volume mount, and Docker only seeds a volume from the image
# when the volume is empty — so an image-time mkdir is invisible on every existing install.
export HARNESS_WORKSPACE="${HARNESS_WORKSPACE:-$DATA_DIR/workspaces}"
mkdir -p "$HARNESS_WORKSPACE"

# The write-wall, in file modes. Idempotent and non-recursive, so it costs nothing on a volume
# that already has it and repairs one that predates it. Session directories themselves are owned
# by their session's uid (0700); the runner sets that as it allocates them.
chown "$PRODUCT:$PRODUCT" "$DATA_DIR" "$HARNESS_WORKSPACE"
chmod 751 "$DATA_DIR" "$HARNESS_WORKSPACE"        # traversable by sessions, neither listable nor writable
for f in "$DATA_DIR"/*.db "$DATA_DIR"/*.db-* "$DATA_DIR"/selfhost-auth.json; do
  if [ -e "$f" ]; then chown "$PRODUCT:$PRODUCT" "$f"; chmod 600 "$f"; fi
done
for d in "$DATA_DIR/blobs" "$DATA_DIR/secrets"; do
  if [ -d "$d" ]; then chown "$PRODUCT:$PRODUCT" "$d"; chmod 700 "$d"; fi
done
# Shared scratch stays USABLE. Sessions get their own TMPDIR inside their workspace (see turn()
# in the runner), but a machine's scratch directories are a convention that tools hardcode, and a
# tool that cannot write /tmp does not fall back: LibreOffice puts its UNO pipe there and dies with
# "no valid pipe path found", which is every .docx/.xlsx/.pptx render and every PDF preview. Closed
# to sessions, one deck task on the demo box spent twenty minutes failing around it before finding
# a way through. Measured both ways under real conditions: closed, no output at all; open as below,
# a 524 KB PDF and its slide render.
#
# 1733, not 1777: a session can CREATE and use paths here (w+x) and the sticky bit stops it
# removing another session's files, but it cannot LIST the directory — so one session cannot
# enumerate another's scratch, which is what shared /tmp otherwise gives away. Deliverables are a
# different question and are answered by the workspace contract, not by this mode: the paths that
# silently swallowed one (the workspace parent, another session's directory) stay closed.
for d in /tmp /var/tmp /dev/shm; do
  if [ -d "$d" ]; then chown root:root "$d"; chmod 1733 "$d"; fi
done

# Our own processes must run on the image's interpreter, never on whatever a backend puts on
# PATH. Hermes installs into its own venv and that venv's bin joins PATH below so the runner can
# spawn `hermes` — but that venv has none of the gateway's dependencies, so resolving `python3`
# through PATH would start the gateway inside it and fail on the first import.
PY=/usr/local/bin/python3

# ── configuration: self-contained defaults ────────────────────────────────────
# Local storage: SQLite + files on the mounted volume. No external services.
export HR_BACKING="${HR_BACKING:-local}"
export HR_DATA_DIR="$DATA_DIR"

# No auth: single-tenant box, identity is a fixed constant rather than something a login
# selects.
export HR_IDENTITY_MODE="${HR_IDENTITY_MODE:-off}"

# No billing or metering: these are hosted concerns and no-op when their URLs are unset.
export HR_CREDIT_GATE="${HR_CREDIT_GATE:-off}"

# The runner is right here, so there is no pool to authenticate to.
export POOL_MGMT_ENDPOINT="${POOL_MGMT_ENDPOINT:-http://127.0.0.1:8081}"
export HR_POOL_AUTH="${HR_POOL_AUTH:-none}"

# Bring your own key: the operator owns the box, the agent and the key, so the key is handed
# to the runner directly instead of being brokered. See _auth_from_conn in gateway/app.py for
# why this is an explicit mode and never a fallback.
export HR_SANDBOX_TRUST="${HR_SANDBOX_TRUST:-owner}"
# Image generation through the broker. Safe to default on HERE and nowhere else: self-hosted is
# bring-your-own-key, so the images an agent makes are billed to the operator's own provider
# account and there is nothing for us to meter.
export HR_BROKER_IMAGES="${HR_BROKER_IMAGES:-1}"

# The gateway signs its own internal calls. Generated per container if not supplied, so a
# default install has no shared secret and nothing to leak; it never leaves this process tree.
if [ -z "${HARNESS_INTERNAL_KEY:-}" ]; then
  export HARNESS_INTERNAL_KEY="$("$PY" -c 'import secrets; print(secrets.token_hex(32))')"
fi

# The gateway itself is unauthenticated — headless, no console gate in front of it. Whatever
# publishes its port is what controls who can reach it (see README: publish to 127.0.0.1 only,
# or put a proxy with its own auth in front, never publish to an open interface unguarded).
export PORT="${PORT:-8080}"

# ── agent CLIs: installed here, not shipped in the image ──────────────────────
# Claude Code is distributed under Anthropic's own terms and hermes-agent declares no license,
# so neither can be redistributed inside a public image. Installing them on first run means the
# operator installs them under those terms, and the image stays redistributable.
#
# They go in the data volume, so this is once per volume rather than once per start. A failure
# to install one backend is not fatal: the others still work, and the gateway's own catalog
# endpoint is what a caller sees, so an unavailable backend simply isn't listed.
TOOLS="$DATA_DIR/agent-tools"
export PATH="$TOOLS/bin:$PATH"
export NODE_PATH="$TOOLS/lib/node_modules"
export HR_BACKENDS="${HR_BACKENDS:-claude,codex,hermes,pi,dsh}"

wanted()   { [[ ",$HR_BACKENDS," == *",$1,"* ]]; }
# The executable IS the definition of "installed" — an installer that exits 0 without producing
# one is still a failed install, and reporting it as success is how a backend silently vanishes
# with no explanation.
backend_bin() {
  case "$1" in
    claude) echo "$TOOLS/bin/claude" ;;
    codex)  echo "$TOOLS/bin/codex" ;;
    hermes) echo "$TOOLS/venv/bin/hermes" ;;
    pi)     echo "$TOOLS/bin/pi" ;;
    dsh)    echo "$TOOLS/dsh-venv/bin/dsh-ready" ;;
  esac
}

# Run an install and, if it fails, SAY WHY.
#
# This was `>/dev/null 2>&1 || true`, and the silence cost a day of someone's life: a root-owned
# npm cache baked into the image made every `npm install` fail with EACCES, and the only trace was
# the "requested but not installed" line further down — which reads like a configuration choice,
# not a broken install. An optional step may fail without stopping start-up; it may not fail
# without leaving the reason where the person looking will find it.
try_install() {
  label="$1"; shift
  log="$(mktemp)"
  if "$@" >"$log" 2>&1; then rm -f "$log"; return 0; fi
  echo "[harnessrouter] WARN: could not install $label — it will not be available:"
  tail -n 12 "$log" | sed 's/^/[harnessrouter]   /'
  rm -f "$log"
  return 1
}

install_backends() {
  mkdir -p "$TOOLS"

  # -g is what creates $TOOLS/bin/<cmd>; --prefix alone just drops a node_modules tree with no
  # entry point, which npm reports as success.
  if wanted claude && [ ! -x "$(backend_bin claude)" ]; then
    echo "[harnessrouter] installing Claude Code (Anthropic's terms apply)…"
    try_install "Claude Code" npm install -g --prefix "$TOOLS" --no-audit --no-fund @anthropic-ai/claude-code || true
  fi

  if wanted codex && [ ! -x "$(backend_bin codex)" ]; then
    echo "[harnessrouter] installing Codex (Apache-2.0)…"
    try_install "Codex" npm install -g --prefix "$TOOLS" --no-audit --no-fund @openai/codex || true
  fi

  if wanted pi && [ ! -x "$(backend_bin pi)" ]; then
    echo "[harnessrouter] installing Pi (MIT) and its MCP adapter (MIT)…"
    # --ignore-scripts is pi's own documented install form. The MCP adapter is a pi extension
    # (github.com/nicobailon/pi-mcp-adapter): pi deliberately ships without MCP, and the runner
    # mounts this adapter via -e only on turns that actually configure MCP servers.
    try_install "Pi" npm install -g --prefix "$TOOLS" --no-audit --no-fund --ignore-scripts \
        @earendil-works/pi-coding-agent pi-mcp-adapter || true
  fi

  if wanted dsh && [ ! -x "$(backend_bin dsh)" ]; then
    echo "[harnessrouter] installing DeepSeek Harness (MIT, developer preview — version-pinned)…"
    # Pinned EXACTLY, not 'latest': upstream is a developer preview that warns of breaking
    # changes, and the runner's driver/normalizer are written against these bytes. An upgrade
    # is an adapter-compatibility change that lands through a PR, never through a fresh volume
    # pulling a newer wheel. Own venv: its dependency tree must not fight hermes's.
    try_install "DeepSeek Harness" sh -c "\"$PY\" -m venv \"$TOOLS/dsh-venv\" \
        && \"$TOOLS/dsh-venv/bin/pip\" install --no-cache-dir -q \
             'deepseek-harness-sdk==0.1.0rc7' 'deepseek-harness-runtime-bin==0.1.0rc7' pyyaml \
        && \"$TOOLS/dsh-venv/bin/python\" -c 'import deepseek_harness, deepseek_harness_runtime, yaml; deepseek_harness_runtime.bundled_runtime_path()' \
        && printf '#!/bin/sh\nexit 0\n' > \"$TOOLS/dsh-venv/bin/dsh-ready\" \
        && chmod +x \"$TOOLS/dsh-venv/bin/dsh-ready\"" || true
    # dsh-ready exists ONLY after the import check proved the runtime executable resolves —
    # a venv whose pip half-failed must not report the backend as available.
  fi

  if wanted hermes && [ ! -x "$(backend_bin hermes)" ]; then
    echo "[harnessrouter] installing Hermes (check its upstream license before use)…"
    try_install "Hermes" sh -c "\"$PY\" -m venv \"$TOOLS/venv\" \
        && \"$TOOLS/venv/bin/pip\" install --no-cache-dir -q \
             'hermes-agent==0.19.0' anthropic '$HERMES_MCP_PIN'" || true
  fi

  [ -d "$TOOLS/venv/bin" ] && export PATH="$TOOLS/venv/bin:$PATH"
  # Hermes otherwise tries to install its own dependencies mid-turn.
  export HERMES_DISABLE_LAZY_INSTALLS=1
  # `wanted hermes && verify_hermes_mcp` looks equivalent and is not: as the LAST command in the
  # function it becomes the function's exit status, so under `set -e` an instance that did not ask
  # for hermes aborted the whole entrypoint — exit 1, no message, the log ending on an install line
  # so it read as if the install had killed it. HR_BACKENDS=claude, =codex and =claude,codex were
  # all unusable, which is exactly the choice the licence note above asks people to make.
  # Where the runner finds the MCP extension to mount (-e) on pi turns with MCP servers.
  [ -d "$TOOLS/lib/node_modules/pi-mcp-adapter" ] && export HR_PI_MCP_EXT="$TOOLS/lib/node_modules/pi-mcp-adapter"
  [ -x "$TOOLS/dsh-venv/bin/python" ] && export HR_DSH_PYTHON="$TOOLS/dsh-venv/bin/python"
  if wanted hermes; then verify_hermes_mcp; fi
}

# hermes 0.19.0 gates HTTP MCP on importing `streamablehttp_client`, the name the mcp SDK
# deprecated and REMOVED in 2.0.0. With an unpinned `mcp`, pip resolves 2.0.0, that import fails,
# and hermes disables HTTP MCP entirely — every remote MCP server a user configures is dropped with
# only a line in a log file inside the workspace. The agent then answers "I can't access that tool",
# which reads as a model refusal rather than a broken install.
#
# So the SDK is pinned below 2.0, and the pin is VERIFIED rather than assumed: lazy installs are
# sealed, so hermes cannot repair this itself, and a volume provisioned before the pin still has
# the broken version. Checking the exact symbol hermes checks turns a silent capability loss into
# one line on start-up — and repairs it in place.
HERMES_MCP_PIN="${HERMES_MCP_PIN:-mcp>=1.9,<2}"

verify_hermes_mcp() {
  [ -x "$TOOLS/venv/bin/python" ] || return 0
  "$TOOLS/venv/bin/python" - <<'PYEOF' && return 0
try:
    from mcp.client.streamable_http import streamablehttp_client  # noqa: F401
except Exception:
    raise SystemExit(1)
PYEOF
  echo "[harnessrouter] repairing Hermes MCP support (installed mcp SDK lacks the transport it needs)…"
  "$TOOLS/venv/bin/pip" install --no-cache-dir -q "$HERMES_MCP_PIN" >/dev/null 2>&1 || true
  if "$TOOLS/venv/bin/python" -c "from mcp.client.streamable_http import streamablehttp_client" 2>/dev/null; then
    echo "[harnessrouter] Hermes MCP support restored"
  else
    echo "[harnessrouter] WARNING: Hermes cannot use HTTP MCP servers — remote tools will be unavailable on that backend"
  fi
}

install_backends

pids=()
cleanup() { trap - TERM INT; for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup TERM INT EXIT

avail=""; missing=""
for b in claude codex hermes pi dsh; do
  wanted "$b" || continue
  if [ -x "$(backend_bin "$b")" ]; then avail="$avail $b"; else missing="$missing $b"; fi
done
echo "[harnessrouter] data=$DATA_DIR  backends available:${avail:- none}"
if [ -n "$missing" ]; then
  echo "[harnessrouter] WARN: requested but not installed:$missing — those backends cannot run"
fi

# runner (loopback only, container-internal). Root, for the per-session uid switch;
# HR_SESSION_UIDS=1 is the declaration the runner fails closed without. The secret-store key is
# the product's and is not in its environment at all.
( cd /app/runner && exec env -u HR_SECRET_KEY \
    HR_SESSION_UIDS=1 "$PY" -m uvicorn server:app --host 127.0.0.1 --port 8081 --log-level warning ) &
pids+=($!)

# gateway, as the product. umask 077: what it creates on the volume (databases, blobs, the
# secret store) is its alone. Bound to every interface, not just loopback, since this is now the
# published port — headless, no console gate in front of it — so whoever publishes it (docker
# run -p, a proxy) is what controls who can reach it; see README.
( cd /app/gateway && exec $AS_PRODUCT sh -c 'umask 077; exec "$0" -m uvicorn app:app --host 0.0.0.0 --port 8080 --log-level warning' "$PY" ) &
pids+=($!)

# Wait for the gateway before declaring ready, so "ready" never races a backend still binding.
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1 && break
  sleep 1
done

echo "[harnessrouter] ready on :$PORT"

# Exit as soon as ANY child exits, carrying its status out to the restart policy.
wait -n "${pids[@]}"
status=$?
echo "[harnessrouter] a process exited (status $status) — shutting down"
exit "$status"
