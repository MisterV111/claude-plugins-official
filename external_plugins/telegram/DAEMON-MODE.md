# Daemon-Mode Architecture

This branch (`telegram/daemon-mode`) contains a fork of the official Telegram plugin patched to fix MCP disconnects under macOS memory pressure, plus mitigations for two related cold-start failure modes.

If you run a Telegram bot bridge to Claude Code on a machine that swaps under load, the upstream plugin will silently lose its connection to `api.telegram.org` and stop delivering messages. This branch addresses that.

> **Status:** running in production on macOS Apple Silicon since 2026-04-20. Soak-tested clean for 7 days. Two known-limitations documented at the bottom of this doc.

---

## The bug (upstream)

**Symptom:** Telegram messages stop arriving in your Claude Code session after a session has been open for hours. The bun MCP child process is still listed in `ps`, but RSS has dropped to ~6 MB, CPU is 0%, and `lsof -p <pid>` shows zero file descriptors.

**Root cause:** the plugin runs as a child of `claude` over stdio MCP transport. Under macOS memory pressure (swap saturated), the kernel evicts the bun child to swap. While swapped out, the plugin's long-poll TCP socket to `api.telegram.org` is dropped by the OS. Bun does not recover the connection cleanly when the process is paged back in. The MCP transport reports a disconnect.

**Why upstream isn't fixing it yet:** related issues are filed (e.g. [#41275](https://github.com/anthropics/claude-code/issues/41275)) but not resolved. The shared root is that MCP children running stdio transport are at the mercy of OS scheduling decisions that the plugin can't observe or recover from.

---

## The architecture

The fix is a process-isolation pattern: take the long-poll socket out of the MCP child entirely.

```
                ┌────────────────────────────────────┐
                │  Telegram Bot API (api.telegram.org)│
                └───────┬─────────────────┬──────────┘
                        │                 │
            getUpdates  │                 │  HTTPS POST
            (long-poll, │                 │  (sendMessage,
             single     │                 │   editMessageText,
             consumer)  │                 │   getFile, etc.)
                        ▼                 ▼
              ┌─────────────────┐   ┌──────────────────┐
              │  DAEMON MODE    │   │  CCT-MODE (shim) │
              │  (launchd-owned)│   │  (stdio MCP)     │
              │                 │   │                  │
              │  Owns polling.  │   │  Reads inbox/    │
              │  Writes JSON    │◄──│  via fs.watch.   │
              │  envelopes to   │   │  Emits MCP       │
              │  inbox/messages/│   │  notifications   │
              │  via atomic     │   │  to Claude Code. │
              │  rename.        │   │  No polling.     │
              └─────────────────┘   └──────────────────┘
```

Two runtime modes for one binary:

1. **Daemon mode** (`bun server.ts --daemon`): owns the bot. Runs under `launchd` (or `systemd`/your init system of choice). Polls Telegram. Writes inbound messages as atomic-rename JSON envelopes to a shared inbox directory. **Has no MCP transport** — it is independent of any Claude Code session.

2. **CCT-mode shim** (`bun server.ts`, default): spawned by Claude Code as a normal MCP child. Reads `bot.pid`; if it sees a `daemon:<pid>` marker, it knows daemon mode is active and **does not** call `bot.start()`. Instead, it watches the inbox directory with `fs.watch`, consumes envelopes, and emits `notifications/claude/channel` to Claude Code. Outbound tools (`reply`, `react`, `edit_message`, `download_attachment`) call `bot.api.*` directly — these are stateless HTTPS POSTs that don't need single-consumer ownership.

The Telegram Bot API has a single-consumer constraint **only on `getUpdates`**. Outbound `bot.api.sendMessage` etc. work without `bot.start()`. This is the core insight that makes the split possible.

If `bot.pid` is missing or has no `daemon:` prefix, the shim falls back to **legacy mode** — the original plugin behavior. This makes the patch backwards-compatible for users who haven't set up the daemon.

---

## Why this works

- **Memory-pressure isolation:** the daemon is owned by `launchd`, not Claude Code. Claude Code (and any cct session) can be killed, OOMed, or swapped out without touching the daemon. The daemon's poll loop runs in its own process with its own memory footprint.
- **Session independence:** opening, closing, and restarting Claude Code sessions does nothing to message delivery. Envelopes queue in the inbox directory until a shim picks them up.
- **Backwards-compatible:** without the daemon running, the plugin behaves exactly like upstream. The patch adds modes; it does not remove behavior.

---

## Install

The patched `server.ts` lives at `external_plugins/telegram/server.ts` on this branch. To run it:

1. Copy or symlink `server.ts` over the version Claude Code uses (typically at `~/.claude/plugins/cache/claude-plugins-official/telegram/<version>/server.ts`).
2. Also overwrite the marketplace copy at `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts` — Claude Code's plugin refresh syncs marketplace → cache, so if the two diverge your patch gets nuked on the next refresh.
3. Set up a launchd plist (or systemd unit) that runs `bun /path/to/server.ts --daemon` with `RunAtLoad=true` and `KeepAlive=true`. See `examples/com.example.tg-bridge-daemon.plist` for a working macOS example (rename the label and paths to match your setup).
4. Bootstrap the daemon: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.tg-bridge-daemon.plist`.
5. Verify: `cat ~/.claude/channels/telegram/bot.pid` should show `daemon:<pid>`.
6. Open a Claude Code session. The shim will detect the daemon and read from the inbox.

For an automated installer that handles cache + marketplace sync, plist install, bootstrap retry, and drift detection, see the install script pattern in `examples/install.sh` (sketch — adapt to your environment).

---

## Known limitations

### Test 8: cold-start drain race

If a Telegram message arrives while the daemon is up but the shim's MCP handshake is still in flight, the shim's `notifications/claude/channel` may be dropped on the floor before Claude Code's listener is registered. Match for upstream issue [#41275](https://github.com/anthropics/claude-code/issues/41275). Working fix path: a daemon-readiness gate (lock file written after first successful poll) + a shim-side post-handshake gate. Not yet shipped on this branch — backlog.

### Test 9: SIGKILL recovery offset corruption

If the daemon is `kill -9`'d and `launchd` respawns it within ~2s, Grammy's long-poll offset state can advance past unprocessed messages during the socket handover (the killed daemon doesn't ack its last batch; the new daemon polls with the next offset). The lost messages can be recovered by `launchctl kickstart -k gui/$(id -u)/<label>`, which forces a graceful restart. Normal failure mode on macOS is graceful exit, not SIGKILL, so this edge case is accepted with a documented workaround.

---

## Other patches in this branch

- **Phantom-shim mutex** (`shim.lock`): Cursor's extension host auto-spawns Telegram plugin instances that bypass `claudeCode.channelsEnabled:false` by launching `bun run start` directly. Without a mutex, multiple shims race to consume the same envelope; the loser's dispatch fails. Implemented as last-writer-wins with stale-PID auto-recovery via `process.kill(pid, 0)`.
- **MCP handshake gate**: certain code paths previously dispatched notifications before `server.oninitialized` fired. Now gated.

---

## Upstream merging

This branch tracks `anthropics/claude-plugins-official:main` as `upstream`. After every release that touches `external_plugins/telegram/`:

```bash
git fetch upstream
git merge upstream/main
# resolve conflicts in external_plugins/telegram/server.ts
# rerun your install script to rehydrate the cache + marketplace copies
```

---

## Context

This patch was developed at [Inspired Creative Group](https://github.com/MisterV111) while triaging recurring MCP disconnects on a workstation running heavy AI production workloads. The diagnosis took longer than the fix — process inspection (`lsof`, `ps`, swap metrics, MCP stdout capture) ruled out plugin bugs and pointed at OS-level socket eviction. Once the root cause was clear, the daemon-split was a natural fit for a problem that was fundamentally about process lifecycle, not protocol logic.

Open to upstream PRs once Anthropic engages on the related issues. In the meantime, this branch is here so anyone hitting the same failure mode has somewhere to start.
