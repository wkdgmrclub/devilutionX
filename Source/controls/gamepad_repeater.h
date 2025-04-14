#pragma once

#include "controller.h"
#include <cstdint>
#include <unordered_map>

namespace devilution {

class GamepadActionRepeater {
public:
	explicit GamepadActionRepeater(int repeatIntervalMs = 10);

	bool ShouldFire(const ControllerButtonCombo &combo);

private:
	std::unordered_map<ControllerButton, Uint32> lastTriggerTime_;
	int repeatIntervalMs_;
};

} // namespace devilution
