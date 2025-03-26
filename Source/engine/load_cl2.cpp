#include "engine/load_cl2.hpp"

#include <cstdint>
#include <memory>
#include <utility>

#include "mpq/mpq_common.hpp"
#include "utils/str_cat.hpp"

#ifdef UNPACKED_MPQS
#include "engine/load_clx.hpp"
#else
#include "engine/load_file.hpp"
#include "mpq/mpq_reader.hpp"
#include "mpq/mpq_sdl_rwops.hpp"
#include "options.h"
#include "utils/cl2_to_clx.hpp"
#endif

namespace devilution {

OwnedClxSpriteListOrSheet LoadCl2ListOrSheet(const char *pszName, PointerOrValue<uint16_t> widthOrWidths)
{
	char path[MaxMpqPathSize];
	*BufCopy(path, pszName, DEVILUTIONX_CL2_EXT) = '\0';
#ifdef UNPACKED_MPQS
	return LoadClxListOrSheet(path);
#else
	size_t size = 0;
	std::unique_ptr<uint8_t[]> data;

	if (!gbIsHellfire && *sgOptions.Enhanced.enableMonkDiablo && strncmp(pszName, "plrgfx\\monk\\", 12) == 0) {
		const char *filename = path;
		uint32_t fileNumber;

		if (hfmonk_mpq && hfmonk_mpq->GetFileNumber(MpqArchive::CalculateFileHash(filename), fileNumber)) {
			if (SDL_RWops *rwops = SDL_RWops_FromMpqFile(*hfmonk_mpq, fileNumber, filename, false)) {
				size = SDL_RWsize(rwops);
				data = std::make_unique<uint8_t[]>(size);
				SDL_RWread(rwops, data.get(), 1, size);
			}
		}
		if (!data && hellfire_mpq && hellfire_mpq->GetFileNumber(MpqArchive::CalculateFileHash(filename), fileNumber)) {
			if (SDL_RWops *rwops = SDL_RWops_FromMpqFile(*hellfire_mpq, fileNumber, filename, false)) {
				size = SDL_RWsize(rwops);
				data = std::make_unique<uint8_t[]>(size);
				SDL_RWread(rwops, data.get(), 1, size);
			}
		}
		if (!data && hfvoice_mpq && hfvoice_mpq->GetFileNumber(MpqArchive::CalculateFileHash(filename), fileNumber)) {
			if (SDL_RWops *rwops = SDL_RWops_FromMpqFile(*hfvoice_mpq, fileNumber, filename, false)) {
				size = SDL_RWsize(rwops);
				data = std::make_unique<uint8_t[]>(size);
				SDL_RWread(rwops, data.get(), 1, size);
			}
		}
	}

	if (!data)
		data = LoadFileInMem<uint8_t>(path, &size);

	return Cl2ToClx(std::move(data), size, widthOrWidths);
#endif
}

} // namespace devilution
