# LuaNet

A generic, reusable **net-message multiplexer** for DevilutionX Lua mods, distributed as a
companion `.mpq`. Any mod that wants custom multiplayer netcode in Lua enables the LuaNet mpq
alongside it and talks to other clients over named channels — without touching the engine.

LuaNet is mod-agnostic: it knows nothing about any particular mod's data or protocol. It only
routes opaque bytes to the right handler on the right client.

---

## Engine dependency (separate from any consuming mod)

LuaNet is the Lua half of a two-part design. The other half is a **generic engine net pipe** that
must exist in the DevilutionX build:

- `system.netSend(payload, mask)` — send opaque bytes to other clients (default mask = all others;
  no-op in single-player).
- the `devilutionx.events` **`NetMessage`** event — fired on receipt as `(senderId, payload)`.

That pipe is a single, mod-agnostic engine primitive (`CMD_LUAMSG` / `TCmdLuaMsg` /
`NetSendCmdLuaMessage` / `OnLuaMessage`). It is **fully generic** — it names no mod and carries no
mod logic; it only moves opaque bytes, and with no mod loaded the engine behaves exactly as vanilla.
That generic-and-clean property is the invariant that matters, independent of how the change is
packaged for review (it may ship in the same PR as LuaNet and its consumers).

LuaNet has **no other engine requirement** and adds no engine code of its own.

---

## API

```lua
local luanet = require("mods.luanet.api")

-- Receive: register (or replace) a handler for a named channel.
-- payload arrives with the channel frame already stripped.
luanet.register("mymod", function(senderId, payload)
  -- decode payload however your mod likes (string.unpack, |-split, JSON, ...)
end)

-- Send: opaque bytes on a named channel. mask is optional (default = every other client).
luanet.send("mymod", payload)
luanet.send("mymod", payload, 1 << targetPlayerId)

-- Stop receiving on a channel (not an error if it was never registered).
luanet.unregister("mymod")

-- Convenience passthrough.
luanet.isMultiplayer()
```

The `payload` is always **opaque mod-defined bytes** — binary-safe, may contain embedded zeros,
may be empty. LuaNet never interprets it.

---

## How channels work

Every message is framed as a **length-prefixed channel name** (`string.pack("s1", channel)`)
followed by the mod's body. On receipt LuaNet unframes the name, looks up the channel's handler,
and delivers the remaining bytes; messages for channels with no local handler are dropped.

Using the channel **name** (not a hash or a registration-order id) as the identity is deliberate:

- **Deterministic across clients** — the name is identical on every machine regardless of mod load
  order. An id assigned at registration time could differ per client and silently cross-wire two
  channels.
- **Collision-free** — the full name travels, so two channels can never alias.

Channel names must be ≤ 255 bytes. The few extra bytes per message are negligible: LuaNet traffic
is event-driven, not per-frame.

---

## Conventions & limits

- **One transport.** If a mod uses LuaNet, route *all* of its net traffic through LuaNet. Do not
  mix LuaNet and raw `system.netSend` on the same pipe — a raw payload's first byte would be misread
  as a channel-name length. (LuaNet won't crash on a foreign payload; it just drops it.)
- **Singleton.** `require("mods.luanet.api")` returns the same table to every mod (DevilutionX
  caches required packages per Lua state, shared across all mod sandboxes), so the underlying
  `NetMessage` subscription is installed exactly once.
- **Level scope is the consumer's job.** Net messages are delivered to every other client; whether
  a message is meaningful (e.g. monster slot ids are per-level) is for the consuming mod to validate
  in its handler — LuaNet does not filter by level, player, or game state.
- **Reliability/ordering** are whatever the engine pipe provides (the reliable, ordered channel).
  LuaNet adds no resend, chunking, or RPC layer; those can be built on top per-mod if needed.

---

## Recommended usage pattern: defensive require + in-game warning

> **Why not a plain `require`?** DevilutionX loads each mod's `init` as *optional* and **silently
> swallows** any error it throws. So a plain `require("mods.luanet.api")` that fails (LuaNet mpq not
> enabled, or a load error) does **not** warn the user — it aborts the consumer mod's whole `init`,
> which typically just makes its class/content vanish with no explanation. A "hard require" cannot
> fail loudly here.

So a consumer should load LuaNet **defensively**, fall back to a no-op stub so the rest of the mod
still loads, and surface the reason in-game itself:

```lua
local luanet
do
  local ok, mod = pcall(require, "mods.luanet.api")
  if ok then
    luanet = mod
  else
    -- stash the error string and show it in-game on a later, safe hook (e.g. GameDrawComplete);
    -- net features are dead until the LuaNet mpq is enabled, but single-player still works.
    luanet = { send = function() end, register = function() end,
               unregister = function() end, isMultiplayer = function() return false end }
  end
end
```

`luanet.send` is already a no-op in single-player, so the stub is only reached when the LuaNet mpq
is genuinely missing. Always call `luanet.register` from your `init` (which re-runs on every mod
reload) so the subscription re-attaches to the freshly recreated events table — see below.

## Mod reloads recreate the events table

Toggling **any** mod makes DevilutionX recreate `devilutionx.events`, dropping every subscription.
Because `api.lua` is cached across reloads, LuaNet does **not** subscribe at module load; it
(re)attaches its single dispatcher lazily the first time a consumer calls `luanet.register` after a
reload, and clears stale registrations at that point. Practical rule for consumers: **register your
channel handler from your mod's `init`**, not from a one-time guarded block, so it is re-registered
on each reload.

## Deployment

LuaNet ships as a standalone `.mpq`. Enable it in the mod list together with any mod that depends
on it. It is **not** assumed to be baked into the engine's asset tree — consumer mods `require` it
by package name (`mods.luanet.api`), which resolves only while the LuaNet mpq is mounted.
