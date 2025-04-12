/**
 * @file effects.h
 *
 * Interface of functions for loading and playing sounds.
 */
#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "engine/sound.h"
#include "sound_effect_enums.h"

namespace devilution {

struct TSFX {
	uint8_t bFlags;
	std::string pszName;
	std::unique_ptr<TSnd> pSnd;
};

extern int sfxdelay;
extern SfxID sfxdnum;

bool effect_is_playing(SfxID nSFX);
void stream_stop();
void PlaySFX(SfxID psfx);
void PlaySfxLoc(SfxID psfx, Point position, bool randomizeByCategory = true);
void sound_stop();
void sound_update();
void effects_cleanup_sfx();
void sound_init();
void ui_sound_init();
void effects_play_sound(SfxID);
int GetSFXLength(SfxID nSFX);
void StopSFX(SfxID sfx);

} // namespace devilution
