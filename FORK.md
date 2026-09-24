# This is azmaveth/ex_mcp 1.5.0 plus our patches

Branch `patched-1.5.0` is upstream tag `v1.5.0` (identical to the Hex 1.5.0
package: `lib/` and `mix.exs` match `mix hex.package fetch ex_mcp 1.5.0`) plus
one commit per patch below. Each commit message says why the patch exists and
names the test that fails on plain v1.5.0.

Imp does not use this branch: it depends on Hex `{:ex_mcp, "~> 1.5"}`,
unpatched, and carries what it needed from the old fork itself. Kite, Haven and
Dwell pin one commit of this branch; Dwell overrides Imp's Hex requirement with
it (`override: true`), so one ref serves all three. Move them together.

Read this before changing a pin, dropping a patch, or moving to a newer
upstream release. To move to a newer release: start a new branch at its tag,
cherry-pick the commits below that still have a reason, and run each commit's
test against the plain tag first; a test that passes there means the patch is
no longer needed.

## The patches

| Commit subject | Needed by | Retires when |
| --- | --- | --- |
| Let a client send per-session `_meta` on session/new, load and resume | Dwell | `LifecycleParams` carries `_meta` |
| Return a tool's result when its output validation misses the deadline | Kite | an output-validation timeout no longer fails the tool call |
| Let an ACP client handler return work that runs outside it (`{:async, work, state}`) | Haven | the handler runner can run a callback's work outside the serialized handler |
| Report dropped listener updates through an ordered barrier | Haven | the client reports or prevents dropped listener updates |
| Send a client handler's own error text back to the agent | Haven | a handler can choose the error message the agent sees |
| Fail initialize as soon as the transport closes | Haven | the init wait handles `transport_closed` |
| Fail initialize when the peer sends a request instead of answering | Haven | the init wait refuses a request from the peer |
| Own the adapter bridge's agent and its descendants with erlexec | Haven (Codex) | `AdapterBridge` launches through an owned process group, or takes a launcher option |

What each consumer depends on, and the test there that fails without it:

- **Kite**: output validation. `test/kite/write_outcome_test.exs` "a completed
  post returns its result when output validation misses its deadline".
- **Dwell**: `_meta`. `dwell-operator ask` sends its dry-run flag and context id
  in session/new `_meta`, and fails closed without them.
- **Haven**: the five ACP client patches and owned adapter subprocesses. Its
  `ClientHandler` returns `{:async, ...}` for every long callback and plain
  refusal text, and `Haven.ACP.Bridge` places event barriers and relies on the
  two initialize failures to report an agent that cannot start.

## Patch notes

**Output validation.** Raising `config :ex_mcp, :json_schema,
validation_timeout_ms:` in the consumer was the alternative. It only moves the
threshold: a loaded enough machine still reports a completed write as failed,
and a caller that retries writes twice. Raising it past the client's own
request timeout would be worse: the client would give up first, and a false
failure would become an unknown outcome. The patch keeps input validation's
deadline, which runs before any effect.

**Owned subprocesses.** Upstream's `AdapterBridge` opens its agent as a raw
`Port`; closing it closes a pipe, and a child that ignores EOF keeps running
with everything it started. The patch starts the bridge's agent through
`ExMCP.Internal.OwnedProcess` (erlexec, `{group, 0}`, `kill_group`) and
`UnixProcessTree` for descendants that call `setsid`. Adapters that open their
own ports (Pi) keep upstream's raw ports; no consumer runs them. Known cost:
the root is stopped before it is signalled, so every close waits out the 1 s
kill timeout.

erlexec is an optional dependency with `runtime: false`, started on the first
spawn. Optional, so a consumer that never runs an adapter (Kite) does not build
erlexec's C++ port program; one that does declares `{:erlexec, "~> 2.2"}`
itself (Haven, and Imp for its own stdio servers; Dwell gets it through Imp).
Without it, opening an adapter fails with `{:erlexec_not_installed, _}`. Started
on use because the port program exits with status 4 when `SHELL` is unset,
which is how an MCP host that spawns a program (Kite's stdio server) often
starts it; starting erlexec with ExMCP kept such a program from booting.

Why this is not done from Haven instead. Haven already owns its other agents'
processes with erlexec (`Haven.AgentProcess`), and `ExMCP.ACP.Adapter` lets an
adapter return `:adapter_managed` from `command/1` and run its own subprocess,
as Pi's adapter does. A Haven wrapper around the Codex adapter could start
`codex app-server` through `Haven.AgentProcess` that way, but only by redoing
the bridge's port handling in Haven:

- In managed mode the bridge opens nothing and writes nothing. The Codex
  adapter's `translate_outbound/2` answers with data for the bridge to write
  (`{:ok, iodata, _}` and three `*_and_write` shapes), and with no port the
  bridge answers each with `{:error, :no_port}`; `translate_inbound/2` does the
  same (`:messages_and_write`, `:skip_and_write`). The wrapper would rewrite
  every one of those shapes, and send the adapter's `post_connect/1` initialize
  handshake itself, which the bridge only sends for a port it opened.
- The bridge has no way for a managed adapter to say its process ended: its
  status stays `:ready` and a waiting `receive_message/2` is never answered, so
  the client would not see the agent exit unless the adapter crashed the bridge.
- The line framing and buffer limits the bridge applies to port data would be
  written again.

That is a second copy of `AdapterBridge`'s process handling, with no
end-to-end Codex test in Haven to hold it. The small fix is upstream: an
`AdapterBridge` option that takes a launcher (open, write, close) instead of
`Port.open/2`, so a host can supply an owned process. That would need an
upstream pull request, which the owner sees first.

## Moved out of the fork into our code

Each of these was a fork patch until 1.5.0. Where it went, and why:

- **stdio frames as bytes** (Kite's UTF-8 fix). Upstream 1.5.0 has its own
  byte-mode framing; Kite's official-SDK stdio checks pass on plain 1.5.0.
- **Owned stdio MCP servers and a clean child `PATH`**: Imp (`Imp.MCP.OwnedStdio`).
  ExMCP's own stdio client transport is upstream's again; no consumer of this
  branch starts MCP servers through it.
- **`ExMCP.Transport.child_environment/1` and the release-`PATH` strip**:
  Haven (`Haven.ACP.ChildEnvironment`), which also gives the Codex adapter a
  clean `PATH` through the adapter's `env` option.
- **Refusing HTTP and SSE MCP servers the agent did not advertise**: Haven
  (`Haven.MCPServer.check_agent_supports/2`).
- **Keeping Codex session config across a late `thread/started`**: Haven
  (`Haven.ACP.CodexAdapter`, a wrapper around upstream's adapter).
- **Codex not replaying history on `session/load`**: dropped. ACP's
  `session/load` replays by design and Haven discards everything inside the load
  window; Haven now also takes the drop count the replay leaves behind with a
  barrier when the window opens, so a long replay cannot fail the next turn.
- **Per-connection trust for remote MCP origins**: Imp trusts an exact origin
  VM-wide while a connection to it is open (`Imp.MCP.Trust`). ExMCP accepts a
  per-connection `security:` option and does not pass it to its check.
- **HTTP client options public servers need** (no self-asserted `Origin`, a
  written `/` path, falling back from the `server/discover` probe on a 4xx):
  Imp (`Imp.MCP.Connections`).
- **Application-owned OAuth browser flow and issuer-matching discovery**: Imp
  (`Imp.MCP.OAuth.Flow`) and Haven (`Haven.MCPOAuth.Flow`, a copy).
- **`connection_info/1`**: Haven (`Haven.ACP.Transport.Initialize`). A thin
  transport wrapper around Haven's agent transports reports the initialize
  request's params and the agent's initialize result to the process calling
  `start_link/1`, and Haven records them as before; `agentInfo` is readable no
  other way.
- **Fixed upstream by 1.5.0**: duplicate Codex final messages (upstream emits
  only the unstreamed remainder).
- **Codex approvals reaching the person**: not fixed upstream in general, and not
  patched. 1.5.0 sends `approvalsReviewer` per mode: `"read-only"` sends
  `"user"`, but the default mode `"agent"` sends `"auto_review"`, which lets
  Codex approve its own requests, and `"agent-full-access"` asks for no
  approval at all. Haven is safe because it starts Codex in `"read-only"`;
  Haven makes that structural (it refuses to start Codex in a mode whose
  approvals do not reach the person, with a test). Note that 1.5.0's
  `"read-only"` mode uses the `workspace-write` sandbox; what keeps it
  read-only in practice is that every write asks the person.
- **Dropped with no consumer**: forwarding `handler_args` as `handler_opts` to
  the HTTP server transport (1.5.0 still does not; no consumer runs an ExMCP
  HTTP server with handler arguments), and the `git_hooks` auto-install
  setting (development of this repository only).

## Known upstream behaviour, not patched

- **Caller-owned MCP requests.** When the process that called
  `ExMCP.Client.call_tool/4` exits, 1.5.0 keeps the request pending until its
  timeout and does not tell the server. The old fork cancelled it. No consumer
  of this branch depends on it; Imp runs on unpatched 1.5.
- **One HTTP server, one request at a time per client.** ExMCP's HTTP client
  serializes the calls to a server inside its client process, so parallel calls
  to one server need several clients (Imp keeps a pool).
- **Buffered stdio frames.** `ExMCP.Transport.Stdio.receive_message/2` returns
  one frame per port message and waits for the next port message before it
  reads the frames already in its buffer, so a response that arrives in the
  same read as an update can sit there until the peer writes again. The old
  fork's master fixed it (`deepfates/ex_mcp#12`). No consumer of this branch
  reads through that transport: Haven uses its own transport for agents,
  Dwell reaches residents over Imp's socket transport, and Kite's stdio is
  the server side. Add the fix here if one starts to.
- **`pi_test` leaks a VM.** `test/ex_mcp/acp/adapters/pi_test.exs` "managed
  model confirmation does not repeat the full model catalog" opens
  `elixir -e "Process.sleep(:infinity)"` with a raw port and closes it in
  `on_exit`, which runs after the test process (the port's owner) is gone, so
  the port is already closed and the VM, which ignores stdin EOF, keeps running
  with ppid 1. One leaks on every run, and it holds the runner's stdout open,
  so `mix test ... | grep` does not return until it is killed. An upstream test
  defect; not patched.
- **Multi-round (MRTR) errors.** A multi-round continuation returns a later
  round's error in the same shape as an error before the first request was
  sent, so a caller cannot tell "not sent" from "sent, then failed" from the
  error alone. A caller that must know treats any error after the first round as
  an unknown outcome.

## Nothing goes upstream without the owner

No issues, pull requests, comments or messages to `azmaveth/ex_mcp` or anywhere
else unless it is unavoidable, minimal, and the owner has seen it first.
`azmaveth/ex_mcp#41` was opened without that on 2026-09-09 and closed.
