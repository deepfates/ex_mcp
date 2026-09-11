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

## If you are about to change a pin

Run the consumer's own interoperability check, not just its unit tests. For Kite
that is `mix test test/kite/stdio_test.exs` with `MCP_CLIENT_PATH` set; without
those packages the check silently skips and a skip reads like a pass.
