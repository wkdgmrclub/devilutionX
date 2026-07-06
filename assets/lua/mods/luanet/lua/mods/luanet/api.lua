-- LuaNet — a generic, reusable net-message multiplexer for DevilutionX Lua mods.
--
-- DevilutionX exposes exactly ONE engine net pipe to Lua: system.netSend(payload, mask) sends
-- opaque bytes to other clients, and they arrive on every other client via the
-- devilutionx.events NetMessage event as (senderId, payload). The engine never interprets the
-- payload -- it only moves bytes. (That pipe is a generic, mod-agnostic engine feature; see
-- README.md "Engine dependency".)
--
-- That single pipe is shared by every mod and every protocol at once. LuaNet sits on top of it
-- and multiplexes it into named CHANNELS, so that multiple mods (or several independent message
-- protocols inside one mod) can use the wire simultaneously without colliding, and so each
-- handler only ever sees the messages addressed to its channel.
--
-- Channel identity is the channel NAME itself, carried length-prefixed in front of every
-- message. This is deliberate:
--   * Deterministic across clients -- the name is the same on every machine regardless of mod
--     load order. (A hash, or an id assigned in registration order, could differ per client and
--     silently cross-wire two channels.)
--   * Collision-free -- the full name travels, so two channels never alias.
-- The few extra bytes per message are negligible: LuaNet traffic is event-driven (deploys,
-- syncs, ownership changes), not per-frame.
--
-- Convention: if a mod uses LuaNet, ALL of its net traffic should go through LuaNet. LuaNet and
-- raw system.netSend senders must not share the pipe -- a raw payload's first byte would be
-- misread as a channel-name length. (LuaNet tolerates this without crashing; the stray message
-- is simply dropped.)
--
-- Usage (from any mod):
--   local luanet = require("mods.luanet.api")
--   luanet.register("mymod", function(senderId, payload) ... end)   -- receive
--   luanet.send("mymod", payload [, mask])                          -- send (default: all others)
--
-- LuaNet is a singleton: require returns the same table to every mod (DevilutionX caches required
-- packages in a registry shared across all mod sandboxes in a Lua state). Because that cache also
-- survives a mod reload (toggling any mod), this module body runs only ONCE per session even though
-- the engine recreates devilutionx.events -- and therefore drops every subscription -- on each
-- reload. So the NetMessage subscription is NOT installed at module load; it is (re)attached lazily
-- to the live events table the first time a consumer registers after each reload. See
-- ensureSubscribed below.

local system = require("devilutionx.system")

local luanet = {}

-- channel name -> handler(senderId, payload). Reassigned (not mutated) on a reload so the dispatch
-- closure, which reads this upvalue cell, transparently picks up the cleared table.
local handlers = {}

-- The events table our dispatcher is currently subscribed to. The engine recreates
-- devilutionx.events on every mod reload; comparing against the live table tells us when we must
-- re-subscribe.
local subscribedEvents = nil

-- Frame a message: a length-prefixed channel name followed by the mod's opaque body.
-- string.pack("s1", name) emits a single length byte (channel names must be <= 255 bytes) then
-- the name; the body is appended verbatim. The engine pipe is length-prefixed and binary-safe,
-- so both the s1 length byte and any binary body survive embedded zeros.
local function frame(channel, payload)
  return string.pack("s1", channel) .. (payload or "")
end

-- The single underlying receive handler. Unframes the channel name, routes the remaining bytes to
-- that channel's handler, and silently ignores any channel no local handler claims (another mod's
-- traffic, or a channel registered only on the sender). pcall guards against a foreign / malformed
-- payload whose leading byte is not a valid length prefix.
local function dispatch(senderId, payload)
  if payload == nil or #payload < 1 then return end
  local ok, channel, nextPos = pcall(string.unpack, "s1", payload)
  if not ok or type(channel) ~= "string" then return end
  local handler = handlers[channel]
  if handler == nil then return end
  handler(senderId, payload:sub(nextPos))
end

-- (Re)attach the dispatcher to the CURRENT events table. The engine recreates devilutionx.events on
-- every mod reload (any mod toggled), which silently drops all subscriptions; because this module is
-- cached across reloads, a one-time module-load subscription would be lost after the next reload. So
-- we re-acquire the live events table here and, whenever it has changed, clear the (now stale)
-- handler table and re-subscribe. Each consuming mod re-registers from its own init -- which DOES
-- re-run on every reload -- so clearing here is correct: live registrations are repopulated, dead
-- ones (from a since-disabled mod) are dropped.
local function ensureSubscribed()
  local events = require("devilutionx.events")
  if events == subscribedEvents then return end
  subscribedEvents = events
  handlers = {}
  events.NetMessage.add(dispatch)
end

--- Send an opaque payload on a named channel to other clients. No-op in single-player.
--- @param channel string  channel name (<= 255 bytes), matched against register()
--- @param payload string  opaque mod-defined bytes (binary-safe; may be "" or nil)
--- @param mask integer|nil target player bitmask; default = every other client
function luanet.send(channel, payload, mask)
  if not system.isMultiplayer() then return end
  if mask ~= nil then
    system.netSend(frame(channel, payload), mask)
  else
    system.netSend(frame(channel, payload))
  end
end

--- Register (or replace) the handler for a named channel. The handler is called as
--- handler(senderId, payload), with the channel frame already stripped: payload is exactly the
--- bytes the sender passed to luanet.send. Call this from your mod's init (it re-runs every reload)
--- so the subscription is (re)attached to the live events table after a mod toggle.
--- @param channel string
--- @param handler fun(senderId: integer, payload: string)
function luanet.register(channel, handler)
  assert(type(channel) == "string", "luanet.register: channel must be a string")
  assert(#channel <= 255, "luanet.register: channel name must be <= 255 bytes")
  assert(type(handler) == "function", "luanet.register: handler must be a function")
  ensureSubscribed()  -- attach/refresh the dispatcher first; this clears stale handlers on a reload
  handlers[channel] = handler
end

--- Remove a channel handler. Messages on that channel are then ignored (not an error).
--- @param channel string
function luanet.unregister(channel)
  handlers[channel] = nil
end

--- Passthrough convenience: true when the current game is multiplayer.
function luanet.isMultiplayer()
  return system.isMultiplayer()
end

-- Publish onto the shared devilutionx.events table so consumer mods can reach this API WITHOUT a
-- cross-mod require: every mod's require("devilutionx.events") returns this same table instance, so a
-- consumer just reads events.luanet. (require of mods.luanet.api still works too, for anyone who
-- prefers it.)
require("devilutionx.events").luanet = luanet

return luanet
