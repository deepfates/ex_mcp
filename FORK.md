# This is a fork of azmaveth/ex_mcp

Read this before changing a dependency pin, deleting a patch, or merging
upstream. Every patch here exists for a reason that was discovered by running
into it; none of it is drift.

Upstream is alive and moving (1.3.0 shipped 2026-09-05). **Currency matters more
than independence for a protocol library**, so the intent is not to keep this
fork. It is to carry the smallest possible patch set, rebased onto each upstream
release, until each patch is either upstreamed or made unnecessary.

State as of 2026-09-09: diverged at `dfd6d7a` (2026-08-22); 22 commits here that
upstream lacks, 44 upstream commits not here.

## What each consumer needs, and why

Four repositories depend on this fork, at four different commits. That is the
problem this file exists to end.

| Repo | Pin | Needs |
| --- | --- | --- |
| kite | `fdb1dd4` | stdio UTF-8 frames; `OwnedProcess` descendant cleanup |
| dwell / imp_acp | `26284e4` | ACP stdio byte mode; loopback MCP consent |
| haven | `0bb2449` | ACP client barrier + `connection_info`; `child_environment` |

### stdio frames are bytes (`fdb1dd4`, and the ACP equivalents)

Upstream writes frames with `IO.puts` and reads with `IO.read`. Both transcode
according to the device's encoding, which under launchd, systemd, or any host
passing a minimal environment is latin1. One emoji or accented handle then kills
the session with `{:no_translation, :unicode, :latin1}`.

Verified 2026-09-09: Kite compiles cleanly against upstream 1.3.0 but its
official-SDK stdio check times out, and this fork's own unicode test reports
"input was transcoded" when run against upstream.

The same rule had been rediscovered three times in three transports before it
was given one owner in `ExMCP.Stdio`.

### Subprocesses must not outlive their owner (`OwnedProcess`, `UnixProcessTree`)

Upstream's `adapter_bridge/port_runner.ex` and `transport/stdio.ex` use raw
`Port.open`, which leaks. Verified 2026-09-09 against upstream 1.3.0: *two* of
this fork's teardown tests fail there — descendants that create their own
process group survive, and so does a leader that ignores SIGTERM.

`OwnedProcess` uses erlexec with `{group, 0}`, `kill_group` and `kill_timeout`;
`UnixProcessTree` handles what a process group cannot — `setsid` escapees — by
freezing the root, walking to a fixed point, killing, and confirming.

Known consequence, deliberate but worth knowing: the root is `SIGSTOP`ped before
`:exec.stop`, so a child can never handle SIGTERM. Every close pays the full
kill timeout. There is no graceful shutdown path today.

### Haven's ACP client needs delivery it can account for

Upstream drops `session/update` notifications when the listener's mailbox
exceeds its limits, to protect connection liveness — correct if the host is a
UI, because the prompt's return value carries the final text. Haven is not a UI:
it *projects a durable conversation* from that stream, including tool calls and
plans, which the return value cannot reconstruct.

So `event_listener_barrier/2,3` reports how many updates were dropped, and Haven
refuses to store a transcript it knows is incomplete. `connection_info/1` is a
plain accessor for the negotiated initialize result.

The better fix is upstream: let a host declare that it needs lossless delivery,
and apply backpressure instead of dropping. Second best, and available now
without touching this fork: **Haven should not use its busiest GenServer as the
listener** — a dedicated receiving process keeps that mailbox near-empty, which
makes drops structurally unlikely and also removes upstream's per-update
`Process.info(pid, :messages)` copy from the hot path.

### Per-connection MCP trust (`1b2ebc3`)

ACP hosts supply MCP servers per session at runtime, so trust decisions are made
per session by the agent's own policy. Upstream already accepts a per-connection
`security:` option (`transport/http.ex:179`) and simply never passes it to the
guard, which falls back to global config. This is a three-line bug fix, not a
design disagreement — it is the most obviously upstreamable patch here.

### Codex adapter: do not replay history on resume

Upstream's `session/load` asks Codex for `initialTurnsPage` and replays the
transcript as `session/update` notifications. A host that already persists the
conversation would record every turn twice. Haven does persist it, so this fork
removes the replay request.

Do not "restore parity with upstream" here without checking what the host does
with a replay first.

### The HTTP client has to survive ordinary public servers

Three separate patches, all found by pointing the client at public MCP servers
(Scry, Exa, Readwise) and reading the failures.

**No self-asserted `Origin`.** Upstream derives an `Origin` header from the
server's own base URL when `security: %{origin: ...}` is not set. A non-browser
client asserting the server's origin back at it says nothing, and a server that
allow-lists browser origins answers `403 Origin not permitted` — which is what
Scry's `/mcp` does. The header is now sent only when it is configured. Nothing
server-side depended on the client sending it: `ExMCP.HttpPlug` already allows
requests with no `Origin` and protects them with Host validation, and the
localhost `allowed_origins` default in `ExMCP.Server.Transport` exists for
callers that do send one. The comment there that justified the default by "our
client sends an Origin" was corrected.

**A written `/` is a path.** Upstream mapped path `nil`, `""` *and* `"/"` to the
`/mcp/v1` default, so a server that serves MCP at its root (Scry answers
`initialize` on `POST https://mcp.scry.io`) was unreachable — the client posted
to `/mcp/v1` and got a 404. Only a URL with no path at all defaults now.

**An HTTP 4xx on the era probe is not a modern server.** In `:prefer_modern`
the client first sends the nonstandard `server/discover`. A standard server may
refuse that at the HTTP level rather than with a JSON-RPC error (`404` from
Scry, `403` for the origin case above), and
`ConnectionManager.legacy_fallback_evidence?/1` did not count those, so the
client gave up without ever trying the standard `initialize`. Any 4xx except
`401` now counts, on a transport that is still alive. `401` stays out: the HTTP
transport reports it as `{:unauthorized, 401, _, _}` and runs the OAuth
challenge flow, and an auth failure says nothing about the protocol era.

`:prefer_modern` stays the default, deliberately. With the fix it reaches a
standard server in one extra request, cached per endpoint by `EraCache`, and the
mirror-image path is worse: `:prefer_legacy` falls forward only on
`legacy_protocol_failure?/1`, which has the same HTTP-status blind spot and no
safe fix — a 4xx on `initialize` is far more likely a broken endpoint or an auth
problem than evidence that the server is modern. Flipping the default would
trade a bug we have fixed for one we cannot classify.

### A missed output-validation deadline does not fail the tool call

Upstream validates a tool's structured output against its output schema after
the handler has run, under `SchemaPolicy`'s 100ms validation deadline, and
replaces the result with an `isError` result when the deadline passes. The
deadline measures the machine, not the output: under load (load average 25–35)
Kite's official-SDK stdio check failed with "Output validation failed: JSON
Schema validation exceeded 100ms" on tools whose output was correct. For a
write, the effect had already happened, so the caller was told a completed
post failed, and a caller that retries posts twice.

`SchemaPolicy.validate_output/3` is now the one output check for the DSL, the
deprecated `Tools` macro and `Tools.Registry`. A timeout there logs a warning
and returns the result; a real mismatch is still an error. Input validation
(`Helpers.validate_tool_args/2`; the server does not check tool arguments
against `inputSchema` itself) keeps the deadline, since it runs before any
effect and bounds client data.
`test/ex_mcp/server/output_validation_deadline_test.exs` restores the 100ms
default (the suite's `test_helper.exs` widens it) and makes the validator slow
with a sleeping custom format; on upstream's code three of its tests fail, one
for each call site.

This retires when upstream stops turning an output-validation timeout into a
tool failure.

### A stdio frame that arrives with another is not held back

`ExMCP.Transport.Stdio.receive_message/2` (the pull path `ExMCP.ACP.Client`
uses) kept the bytes after the first complete line in `line_buffer`, then
waited for the next port message before looking at them. A pipe hands over
whatever is ready, so an agent that writes a `session/update` and the prompt's
result back to back is often read as one chunk; the result then sat in the
buffer until the agent wrote again, which after a final response is never, and
the caller got `{:error, :request_timeout}` after 30 seconds. The same wait
followed a skipped banner or blank line. Found through Imp's ACP relay test,
which failed this way in 4 of 100 runs on Linux. The buffer is now
drained before waiting. Upstream 1.5.0 has the same code; the test
"every frame of a chunk carrying several is delivered without more output" in
`test/ex_mcp/transport/stdio_isolation_test.exs` fails on it.

This retires when upstream drains the buffer before waiting.

## Do not contact upstream

The intent above is a direction, not a licence to act on it. Nothing leaves
these repositories: no issues, pull requests, comments or messages to
`azmaveth/ex_mcp` or anywhere else, however obviously useful, until the owner
says otherwise. This is a standing decision, and it has been enforced before —
`azmaveth/ex_mcp#41` proposed the server-side stdio patch on 2026-09-09 and was
closed.

So "the most obviously upstreamable patch here" means *if the owner opens that
door*, start with the three-line `security:` fix. It does not mean send it.
Fixes live here, with their reason beside them.

## If you are about to change a pin

Run the consumer's own interoperability check, not just its unit tests. For Kite
that is `mix test test/kite/stdio_test.exs` with `MCP_CLIENT_PATH` set; without
those packages the check silently skips and a skip reads like a pass.
