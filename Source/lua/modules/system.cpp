#include "lua/modules/system.hpp"

#include <sol/sol.hpp>

#ifdef USE_SDL3
#include <SDL3/SDL_timer.h>
#else
#include <SDL.h>
#endif

#include "game_mode.hpp"
#include "lua/metadoc.hpp"
#include "msg.h"
#include "multi.h"
#include "player.h"

namespace devilution {

sol::table LuaSystemModule(sol::state_view &lua)
{
	sol::table table = lua.create_table();

	LuaSetDocFn(table, "get_ticks", "() -> integer", "Returns the number of milliseconds since the game started.",
	    []() { return static_cast<int>(SDL_GetTicks()); });

	LuaSetDocFn(table, "isMultiplayer", "() -> boolean",
	    "Returns true if the current game is multiplayer, false for single-player.",
	    []() { return gbIsMultiplayer; });

	LuaSetDocFn(table, "isHellfire", "() -> boolean",
	    "Returns true if the current game is running in the Hellfire gamemode, false for Diablo.",
	    []() { return gbIsHellfire; });

	// Lua mod support: the synced lockstep tick counter. Multiplayer runs a deterministic lockstep
	// simulation; this counter advances once per game tick identically on every client, and a client
	// that joins mid-game is initialized to the current value (ParseTurn) -- so at a given tick it reads
	// the same number everywhere, even on a late joiner. Use it to make cached or periodic mod decisions
	// JOIN-TIME-INDEPENDENT: derive them from (gameTick, a stable entity id) instead of from when the
	// local client happened to compute them, and every client agrees with no network traffic. This is
	// the same mechanism the engine itself uses to keep per-monster AI RNG in sync (MonsterSeeds). The
	// value is free-running (not reset per level) and meaningless in single-player; only DIFFERENCES /
	// modulo and the cross-client agreement are meaningful.
	LuaSetDocFn(table, "gameTick", "() -> integer",
	    "Returns the synced lockstep game-tick counter, identical across all clients (incl. late joiners) at the same tick. Derive cached/periodic decisions from it (e.g. seed = f(gameTick, entityId)) to keep them deterministic across clients without net traffic. Free-running, not per-level; single-player value is not meaningful. // Lua mod support",
	    []() { return static_cast<uint32_t>(sgdwGameLoops); });

	// Lua mod support: generic net pipe. Send an opaque payload to other clients; it arrives via the
	// NetMessage event. The engine does not interpret the payload — encode/decode it in Lua. Default
	// target is every other player (the local sender applies its own effects directly, mirroring the
	// engine's spawn pattern); pass an explicit player bitmask to override. No-op in single-player.
	LuaSetDocFn(table, "netSend", "(payload: string, mask: integer|nil)",
	    "Send an opaque payload to other clients over the generic Lua net pipe; received via the NetMessage event. Defaults to all other players. No-op in single-player. // Lua mod support",
	    [](const std::string &payload, sol::optional<uint32_t> mask) {
		    // The outgoing packet header is built from the local player, so a send is only valid once
		    // it exists. A mod may reach this from a setup callback that runs before the local player
		    // is established; drop the send rather than dereference a null MyPlayer.
		    if (!gbIsMultiplayer || MyPlayer == nullptr) return;
		    const uint32_t pmask = mask.value_or(0xFFFFFF & ~(1U << MyPlayerId));
		    NetSendCmdLuaMessage(pmask, payload.data(), payload.size());
	    });

	return table;
}

} // namespace devilution
