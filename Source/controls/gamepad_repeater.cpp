#include "gamepad_repeater.h"

#include <SDL.h>

namespace devilution {

GamepadActionRepeater::GamepadActionRepeater(int repeatIntervalMs)
    : repeatIntervalMs_(repeatIntervalMs)
{
}

bool GamepadActionRepeater::ShouldFire(const ControllerButtonCombo &combo)
{
	if (combo.button == ControllerButton_NONE)
		return false;

	if (!IsControllerButtonComboPressed(combo)) {
		lastTriggerTime_.erase(combo.button);
		return false;
	}

	Uint32 now = SDL_GetTicks();
	Uint32 &lastTime = lastTriggerTime_[combo.button];

	if (now - lastTime >= static_cast<Uint32>(repeatIntervalMs_)) {
		lastTime = now;
		return true;
	}

	return false;
}

} // namespace devilution
