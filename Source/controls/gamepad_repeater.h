#pragma once

#include <cstdint>
#include <unordered_map>
#include "controller.h"

namespace devilution {

class GamepadActionRepeater {
public:
	explicit GamepadActionRepeater(int repeatIntervalMs = 10);

	/**
	 * @brief Checks if the given button combo should fire based on the repeat interval.
	 * Must be called once per frame.
	 */
	bool ShouldFire(const ControllerButtonCombo &combo);

private:
	std::unordered_map<ControllerButton, Uint32> lastTriggerTime_;
	int repeatIntervalMs_;
};

} // namespace devilution
