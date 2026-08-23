<div align="center">
  <a href="https://harnessrouter.ai">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset=".github/images/logo-dark.png">
      <source media="(prefers-color-scheme: light)" srcset=".github/images/logo-light.png">
      <img alt="HarnessRouter" src=".github/images/logo-light.png" width="55%">
    </picture>
  </a>
</div>

<div align="center">
  <h3>Run agent harnesses on your own machine.</h3>
</div>

<div align="center">

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![UHP conformance](https://img.shields.io/badge/UHP-class%20Full-brightgreen)](protocol/conformance/)

</div>

<br>

**Run agent harnesses on your own machine.** One container, your own API keys, your
own data. Give a harness work over its API, watch it run, with no account, no cloud, and no
telemetry. Community Edition implements the [Unified Harness Protocol (UHP)](https://unifiedharnessprotocol.org),
the open standard the hosted service implements too.

> [!NOTE]
> **This is a headless fork.** Upstream HarnessRouter ships a browser console; this fork removes
> it entirely — no login page, no UI process, no account to sign in to. Everything here is driven
> by the gateway's own API (`curl`, a script, or your own client), the same `/v1` surface the
> console itself was always a thin client over. See [What changed in this fork](#what-changed-in-this-fork).

> [!TIP]
> New here? Start with [What it is](#what-it-is), or read the protocol at [unifiedharnessprotocol.org](https://unifiedharnessprotocol.org).

---

## What changed in this fork

Two changes from upstream [HarnessRouter](https://github.com/HarnessRouter/harnessrouter), both
deliberate:

- **The console (`ui/`) is gone.** No browser page, no login, no Next.js build stage, no
  `console` CI job. Everything the console did is still reachable — it was always a thin client
  over the gateway's own API — so nothing here is a capability loss, only a UI loss. Because the
  console carried the *only* authentication this product has, removing it means **the gateway's
  API has no auth of its own**; the loopback port binding (step 2) is now the entire access
  control, and that is a real, load-bearing security change to understand before you run this
  anywhere but a machine you trust.
- **Claude Code plugin support.** Upstream's runner drives `claude -p` with no `--plugin-dir` and
  writes only `http`/`sse` MCP servers into `.mcp.json`. This fork adds both: a Claude Code plugin
  (commands, hooks, subagents, its own stdio MCP server) attached to a turn's `plugins` field
  materializes into the session workspace and loads via `--plugin-dir`, verified end to end
  against a real ~150-file plugin. See [Using the API](#using-the-api) for the call shape.

Not built into an image or published anywhere — build it yourself (below). Everything else in
this document describes what's unchanged from upstream, except where noted.

## Install

Five steps, and at the end of them you have a running instance and an agent that has answered you.

You need Docker, about 4 GB of disk, and an API key from a model provider. There is no account to
create and nothing to sign up for. The provider key is the only credential in the story, and it
never leaves the box except to call the provider it belongs to.

### 1. Build the image

This fork is not published to a registry — build it from source:

```bash
git clone <this fork's URL>
cd harnessrouter
docker build -t harnessrouter-fork .
```

A few minutes, most of it native dependencies (LibreOffice, ffmpeg) rather than anything this
fork's own changes touch.

<details>
<summary>Pinning a version instead of <code>latest</code></summary>

`latest` is the current release, and pulling it again is how you upgrade. Pin a version only when
you need two machines to run the same bytes, by naming a version in a compose file you share with a
team. Releases are listed on [Docker Hub](https://hub.docker.com/r/harnessrouter/harnessrouter/tags).

</details>

### 2. Run it

Copy this as it is. Nothing in it is a placeholder — no provider key.

```bash
docker run -d --name harnessrouter \
  -p 127.0.0.1:8080:8080 \
  -v harnessrouter:/data \
  harnessrouter-fork
```

(Build the image locally first — see [Building the image](#building-the-image) — this fork is not
published to a public registry.) If port 8080 is already busy, change only the left-hand number
(`-p 127.0.0.1:8180:8080`), because the container always listens on 8080 inside.

<details>
<summary>What each part of that line does</summary>

`-p 127.0.0.1:8080:8080` keeps the gateway reachable only from this machine. There is no login gate
in this fork — that loopback binding is the entire access control, so do not change the left-hand
address to `0.0.0.0` or publish this port on a network you do not fully trust.

`-v harnessrouter:/data` is where everything durable lives: the database, your files, and the agent
CLIs installed on the first start. Keeping that volume is what makes every later start fast.

No provider key here, because you connect one after the container is up — see step 4. A key never
belongs in a `docker run` command you might paste into a shell history or a script you share.

</details>

<details>
<summary>Do not add <code>--user</code>: the container starts as root and drops privileges itself</summary>

The container must start as root, and refuses to start any other way, with one line saying so. This
is not the usual "runs as root" shortcut; it is the opposite. Root is needed for exactly one thing:
every agent CLI runs as its own per-session user, which owns that session's workspace and nothing
else. Switching to that user is what root is for, and the product itself runs as an unprivileged
user from the first second.

What that buys you, inside one container serving many sessions:

- An agent cannot read or write another session's files, the databases, the blob store or the
  secret store. Not "is told not to": cannot, because those paths belong to other users.
- A file an agent saves to the wrong place fails at the write, while the model is still there to
  correct itself, instead of silently disappearing outside the collected workspace.
- An agent process carries none of the product's secrets in its environment.

No extra privilege is granted to get there: no `--privileged`, no `--cap-add`, no custom seccomp
profile. Docker's default capability set already includes what a root process needs to switch to
another user, and that is all that is used.

</details>

<details>
<summary>Using Docker Compose instead</summary>

`cp .env.example .env`, then `docker compose up -d`. `docker-compose.yml` already publishes
`127.0.0.1:8080:8080`, matching the command above.

</details>

### 3. Wait for it to say it is ready

`docker run` gives your prompt back in about a second, but the first start needs roughly another
half a minute to fetch the agent CLIs — until then the gateway refuses connections. That is the
first start still working, not a broken container.

```bash
docker logs -f harnessrouter
```

Wait for `ready on :8080`:

```
[harnessrouter] installing Claude Code (Anthropic's terms apply)…
[harnessrouter] installing Codex (Apache-2.0)…
[harnessrouter] installing Pi (MIT) and its MCP adapter (MIT)…
[harnessrouter] installing DeepSeek Harness (MIT, developer preview — version-pinned)…
[harnessrouter] installing Hermes (check its upstream license before use)…
[harnessrouter] data=/data  backends available: claude codex hermes pi dsh
[harnessrouter] ready on :8080
```

This wait happens once per volume. Every start after it takes a few seconds and prints no install
lines at all.

<details>
<summary>Why the first start is the slow one</summary>

`backends available:` lists what actually installed, so a backend that failed is named rather than
silently missing, and the others still work.

The agent CLIs are fetched on the first start rather than shipped in the image, and that is a
licensing fact rather than a packaging preference. Claude Code is distributed under Anthropic's own
terms and hermes-agent declares no license at all, so neither can be redistributed inside a public
image. Installing them on first run means you install them yourself, from upstream, under those
terms — which is also why you should read them before you use those two backends. Codex
(Apache-2.0), Pi (MIT, with its MIT-licensed MCP adapter) and DeepSeek Harness (MIT,
a developer preview pinned to an exact version) arrive the same way, so all five land
in one place.

</details>

### 4. Connect a model provider

**Nothing runs until you do this.** There is no bundled model, no trial key, and no free tier
hiding in the image. A connection names a provider and its credential; a policy says which
connection a backend uses:

```bash
-e HR_SECRET_GLOBAL_HARNESS_CONN_ANTHROPIC='{"name":"anthropic","provider":"anthropic","api_key":"sk-ant-…"}'
-e HR_SECRET_GLOBAL_HARNESS_POLICY_CLAUDE='{"chain":["anthropic"]}'
```

Add both to your `docker run` command (or `.env` for compose) and restart the container. There is
one policy variable per backend: `…POLICY_CLAUDE`, `…POLICY_CODEX`, `…POLICY_HERMES`. An
OpenAI-compatible endpoint of your own takes the same pair with a `base_url` added, and
`"provider":"openai"`:

```bash
-e HR_SECRET_GLOBAL_HARNESS_CONN_LOCAL='{"name":"local","provider":"openai","api_key":"…","base_url":"https://api.example.com/v1"}'
-e HR_SECRET_GLOBAL_HARNESS_POLICY_CODEX='{"chain":["local"]}'
```

Not every provider fits every backend, and a pairing that does not fit fails quietly: the turn
comes back empty after a long wait rather than erroring.

| Connection `provider` | Backends that can use it |
|---|---|
| `anthropic` | Claude Code, Hermes, Pi |
| `openai` | Codex, Hermes, Pi |
| `openrouter` | Codex, Hermes, Pi, DeepSeek Harness |
| `azure-foundry` | Codex, Hermes, Pi |
| `bedrock` | Claude Code, Hermes |
| `tokenrouter` | Claude Code, Codex, Hermes, Pi, DeepSeek Harness |
| `vercel` | Claude Code, Codex, Hermes, Pi, DeepSeek Harness |
| `llmtr` | Claude Code, Codex, Hermes, Pi, DeepSeek Harness |

<details>
<summary>What a backend with nothing connected says</summary>

Forthcoming about it, which is what you get if you skip this step entirely:

```json
{"error":{"type":"invalid_request_error","code":"invalid_input","message":"no provider configured for backend 'codex'. Add an integration for a provider that serves 'gpt-5.4-mini', or configure a connection policy"}}
```

</details>

### 5. Give it something to do

Run a turn against the gateway's own API — see [Using the API](#using-the-api) for the full call
and a real response. That is the whole install. State is SQLite and files on one Docker volume.
Delete the volume and the instance is gone; copy it and you have moved the instance, harnesses,
transcripts and all.

---

## Starter kits

Starter kits are worked examples of what this can be pointed at: an app, an agent configured to
drive it, and the skill that teaches that agent the format it writes.

**They still launch from this fork's API** (`GET /v1/kits`, `POST /v1/kits/{kit_id}/launch` — a
kit's own README, in [`HarnessRouter/starter-kit`](https://github.com/HarnessRouter/starter-kit),
has the exact call). What changes without a console: several kits — Slides, Sheets, Dashboards —
produce an app meant to be *worked in* visually (drag a slide element, click a sheet cell, resize a
dashboard panel), and that editor is itself a browser page this fork does not serve. Launching one
here gets you the harness, the agent, and the generated content on disk in the task's workspace;
opening and rearranging it interactively is not something this fork's API replaces. If that
interactive surface matters to you, upstream HarnessRouter (with its console) or the hosted service
are the places to run those specific kits, not this fork.

---

## What it is

An *agent harness* is the runtime layer around a model; Codex, Claude Code, and Hermes are harnesses. In this repo's API you also create *harness* objects: a saved configuration whose `base` is one of those runtimes, plus a model, instructions, and limits. A *task* is one run of that configuration, a real conversation against a real POSIX workspace with bash and git, streamed back as it happens.

HarnessRouter Community Edition implements UHP for both: an OpenAI **Responses-compatible** API for
running turns, harness CRUD, sessions, streaming, cancellation, and idempotency. Upstream ships a
browser console as a thin client over that API; this fork removes the console and keeps only the
API it was a client of — see [What changed in this fork](#what-changed-in-this-fork).

**Supported harnesses:** Codex, Claude Code, and Hermes, installed on first run rather than shipped
in the image, for the license reasons in step 3. Review each tool's terms before you use it. This
fork adds Claude Code plugin support (`--plugin-dir`, stdio MCP servers) beyond what upstream's
runner does today.

**Bring your own key.** Your provider credentials are read from the environment at start-up and
handed to the agent directly. They are never written into the image, never committed, and never
sent anywhere but your provider.

## Why self-host

- **Your keys, your bills, your data.** Nothing leaves the box except calls to your model provider.
- **Real workspaces.** Agents get bash, git, and a filesystem, their native environment, not a
  sandbox emulation.
- **The same API as the hosted product.** Not a reduced fork: the same `/v1` surface, so anything
  you build against it keeps working if you later move to the hosted service.
- **Actually self-contained.** No control plane to phone home to, no managed database.

## The Unified Harness Protocol

This repository is both an implementation and a standard. The protocol the gateway speaks is
specified, versioned and testable in [`protocol/`](protocol/), and documented at
[unifiedharnessprotocol.org](https://unifiedharnessprotocol.org):

| | |
|---|---|
| [Specification](protocol/versions/2026-08-11/) | Ten normative chapters, version `2026-08-11` |
| [Machine-readable](protocol/schema/) | OpenAPI 3.1 + JSON Schema 2020-12, generated from one source |
| [Conformance suite](protocol/conformance/) | passing it is what "conformant" means, and what earns the right to the UHP name |
| [Governance](protocol/GOVERNANCE.md) | How the standard changes, and the naming and conformance policy |

This edition is the reference implementation. The most recent published run
[passes at class Full](protocol/conformance/reports/harnessrouter-ce-0.3.0.json), against 0.3.0.
**The standard can be implemented without HarnessRouter Cloud**: it is an HTTP contract, and
nothing in it requires a hosted service. Run the suite against your own server:

```bash
pip install -e protocol/conformance
uhp-conformance --base-url https://your-server --api-key "$KEY" --class full
```

## Configuration

<details>
<summary>Choosing backends, and building with browser automation</summary>

Backends are installed into your data volume rather than baked into the image, so which ones you
want is a run-time setting:

```bash
docker run -e HR_BACKENDS=claude,codex,hermes ...   # the default
```

**Known issue: any value that leaves out `hermes` makes the container exit immediately**
with status 1 and no error message. `claude`, `codex` and `claude,codex` all do it, and the last
line in the log is the install line for the backend it was working on, so it reads as if the
install killed it, which it did not. Until that is fixed, leave `HR_BACKENDS` unset.

Chromium is genuinely an image layer, so it stays a build flag:

```bash
docker build -t harnessrouter --build-arg WITH_BROWSER=1 .
```
</details>

<details>
<summary>What the entrypoint sets for you</summary>

| Variable | Default | Why |
|---|---|---|
| `HR_BACKING` | `local` | SQLite + files on `/data`. No external storage. |
| `HR_IDENTITY_MODE` | `off` | One box, one owner; an accounts system would be ceremony with nothing behind it. |
| `HR_CREDIT_GATE` | `off` | Metering is a hosted concern. |
| `POOL_MGMT_ENDPOINT` | `http://127.0.0.1:8081` | The runner is in this container. |
| `HR_POOL_AUTH` | `none` | No cloud identity to present to a loopback runner. |
| `HR_SANDBOX_TRUST` | `owner` | You own the box, the agent and the key, so the key is handed over directly rather than brokered. |
| `HARNESS_WORKSPACE` | `/data/workspaces` | One directory per session, on the volume, so a restart doesn't discard work in flight. |
| `HR_WORKSPACE_TTL_HOURS` | `72` | Idle session workspaces are removed after this. They rehydrate from their checkpoint, so this costs time, not work. `0` keeps them forever. |
| `HARNESS_INTERNAL_KEY` | generated | Per-container; never leaves the process tree. |

</details>

## Using the API

There is no login step in this fork — the gateway itself has no authentication of its own, so
`docker run -p 127.0.0.1:8080:8080` is the entire access control (see the note in step 2). Call it
directly:

```bash
curl -s http://localhost:8080/v1/responses \
  -H 'content-type: application/json' \
  -d '{"input":"Reply with exactly this and nothing else: it works.",
       "metadata":{"harness_id":"codex"},
       "model":"gpt-5.4-mini",
       "stream":false}'
```

```json
{"id":"resp_284e450bc2be4de8bea94c4af6030292","object":"response","created_at":1786822334,
 "status":"completed","error":null,"incomplete_details":null,"previous_response_id":null,
 "model":"gpt-5.4-mini",
 "output":[{"id":"msg_3d71e018c6584abbb063ee16d9a36e75","type":"message","status":"completed",
            "role":"assistant",
            "content":[{"type":"output_text","text":"it works.","annotations":[]}]}],
 "store":true,
 "usage":{"input_tokens":10878,"output_tokens":34,"total_tokens":10912},
 "metadata":{"session_id":"hsessa79756fab07a4bf58fa072be24d5ce59"}}
```

<details>
<summary>The rest of the surface</summary>

`harness_id` accepts one of the built-in ids: `codex`, `claude-code`, `hermes`, `pi`, `dsh`, or the
id of a harness you created via harness CRUD (`/v1/harnesses`). The model catalog (`/v1/models`),
sessions (`/v1/sessions/{id}/turns`, `/cancel`) and task listing (`/v1/traces`) are all on the same
prefix. Set `"stream":true` for server-sent events instead of one response at the end.

</details>

<details>
<summary>Running a Claude Code plugin (this fork's addition)</summary>

Attach a plugin's files directly to a turn — no install step, no marketplace, materialized fresh
into the session workspace and loaded via `--plugin-dir`:

```bash
curl -s http://localhost:8080/v1/responses \
  -H 'content-type: application/json' \
  -d '{"input":"call the shape tool and report what it says",
       "metadata":{"harness_id":"claude-code"},
       "model":"claude-sonnet-5",
       "plugins":[{"name":"my-plugin","files":[{"path":".claude-plugin/plugin.json","content":"..."}, ...]}],
       "stream":false}'
```

A plugin's hooks (`hooks/hooks.json`) and its own MCP server fire exactly as they would in a
native, interactive Claude Code session — this was verified directly against a real ~150-file
plugin, not assumed from the CLI's docs. See `runner/server.py`'s `_write_plugins`/`_build_claude`
for the exact mechanics, and `runner/tests/test_claude_plugins.py` for the test coverage.

</details>

## Putting it on a public URL

**This fork has no login gate at all — do not publish the gateway's port to anything but
`127.0.0.1` without adding your own authentication in front of it first.** Whoever can reach it
can create harnesses, read every task transcript, and run an agent with your provider key. That
is what the loopback binding in step 2 is for, and it is the *only* thing standing in the way —
there is no `HR_AUTH_DISABLED` to worry about leaving on, because there is no gate to disable.

If you genuinely need remote access, put your own authenticating proxy in front — Caddy with
`basic_auth`, an OAuth-aware proxy, a VPN, or an SSH tunnel from the client machine — and keep the
gateway itself bound to loopback regardless:

```caddyfile
gateway.example.com {
    basic_auth {
        you $2a$14$...    # bcrypt hash — `caddy hash-password` generates one
    }
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1      # agent turns stream for minutes; never buffer them
    }
}
```

The `flush_interval -1` matters: without it a proxy buffers the event stream and a caller sees
nothing until the turn ends.

## Architecture

```
┌─ container ─────────────────────────────────────────────┐
│  Gateway       :8080  ← the only published port          │
│      │ loopback                                          │
│  Runner        :8081  one agent CLI per session          │
└─────────────────────────┬───────────────────────────────┘
       /data (volume): SQLite, files, secrets, workspaces
```

The runner listens on loopback inside the container and is not publishable; the gateway's port is
the way in. This fork has no console and no login gate in front of that port — see the warning
above.

Sessions run concurrently and are isolated: each gets its own workspace directory, its own
conversation state, and its own checkpoint. Turn concurrency defaults to the machine's core
count. This box cannot scale sandboxes on demand the way the hosted deployment does, so the
limit is what it can actually run.

Storage sits behind a small adapter interface for records, files, and secrets. This repo ships the
local implementations; the hosted deployment supplies its own against the same interface. That
seam is why this is genuinely the same codebase rather than a fork that drifts.

## Resources

- **[Documentation and Cloud](https://harnessrouter.ai)**: hosted service, guides, and pricing.
- **[Unified Harness Protocol](https://unifiedharnessprotocol.org)**: the open standard this repository implements.
- **[Starter Kit](https://github.com/HarnessRouter/starter-kit)**: runnable example applications built on Community Edition.
- **[Discord](https://discord.gg/nPcbwqVPb2)**: community for questions, integrations, and proposals.
- **[Contributing](CONTRIBUTING.md)** and **[Security](SECURITY.md)**: how to propose changes and report vulnerabilities.

## License

Apache-2.0, see [LICENSE](LICENSE). Third-party notices are in [NOTICE](NOTICE).

The agent CLIs are **not** redistributed here; they are installed on first run under their own
licenses. Review them before enabling a backend.
