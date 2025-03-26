#include "engine/load_pcx.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <utility>

#ifdef DEBUG_PCX_TO_CL2_SIZE
#include <iostream>
#endif

#include <SDL.h>

#include "mpq/mpq_common.hpp"
#include "utils/log.hpp"
#include "utils/str_cat.hpp"

#ifdef UNPACKED_MPQS
#include "engine/load_clx.hpp"
#include "engine/load_file.hpp"
#else
#include "engine/assets.hpp"
#include "mpq/mpq_reader.hpp"
#include "options.h"
#include "utils/pcx.hpp"
#include "utils/pcx_to_clx.hpp"
#endif

#ifdef USE_SDL1
#include "utils/sdl2_to_1_2_backports.h"
#endif

extern std::optional<devilution::MpqArchive> hellfire_mpq;

namespace devilution {

OptionalOwnedClxSpriteList LoadPcxSpriteList(const char *filename, int numFramesOrFrameHeight, std::optional<uint8_t> transparentColor, SDL_Color *outPalette, bool logError)
{
	char path[MaxMpqPathSize];
	char *pathEnd = BufCopy(path, filename, DEVILUTIONX_PCX_EXT);
	*pathEnd = '\0';
#ifdef UNPACKED_MPQS
	OptionalOwnedClxSpriteList result = LoadOptionalClx(path);
	if (!result) {
		if (logError)
			LogError("Missing file: {}", path);
		return result;
	}
	if (outPalette != nullptr) {
		std::memcpy(pathEnd - 3, "pal", 3);
		std::array<uint8_t, 256 * 3> palette;
		LoadFileInMem(path, palette);
		for (unsigned i = 0; i < 256; i++) {
			outPalette[i].r = palette[i * 3];
			outPalette[i].g = palette[i * 3 + 1];
			outPalette[i].b = palette[i * 3 + 2];
#ifndef USE_SDL1
			outPalette[i].a = SDL_ALPHA_OPAQUE;
#endif
		}
	}
	return result;
#else
	size_t fileSize;
	AssetRef ref;

	if (!gbIsHellfire && *sgOptions.Enhanced.enableMonkDiablo && strcmp(path, "ui_art\\heros.pcx") == 0 && hellfire_mpq) {
		const devilution::MpqArchive::FileHash hash = devilution::MpqArchive::CalculateFileHash(path);
		uint32_t fileNumber;
		if (hellfire_mpq->GetFileNumber(hash, fileNumber)) {
			ref.archive = &*hellfire_mpq;
			ref.fileNumber = fileNumber;
			ref.filename = path;
			fileSize = ref.size(); // Needed for correct allocation
		}
	} else {
		ref = FindAsset(path);
		if (!ref.ok())
			return std::nullopt;
		fileSize = ref.size();
	}

	AssetHandle handle = OpenAsset(std::move(ref));
	if (!handle.ok())
		return std::nullopt;

	return PcxToClx(handle, fileSize, static_cast<int>(numFramesOrFrameHeight), transparentColor, outPalette);
#ifdef DEBUG_PCX_TO_CL2_SIZE
	std::cout << filename;
#endif
	OptionalOwnedClxSpriteList result = PcxToClx(handle, fileSize, numFramesOrFrameHeight, transparentColor, outPalette);
	if (!result)
		return std::nullopt;
	return result;
#endif
}

} // namespace devilution
