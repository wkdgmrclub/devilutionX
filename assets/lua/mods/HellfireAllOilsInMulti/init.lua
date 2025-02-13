local items = require("devilutionx.items")

local CF_SINGLE = 0x01 -- Define bit flag for enforcing SP oil drops in MP

-- Define oil level requirements, matching original logic
local OilLevels = {
    [IMISC_OILACC]  = 1,  -- Oil of Accuracy (already valid in MP)
    [IMISC_OILMAST] = 10, -- Oil of Mastery (missing in MP)
    [IMISC_OILSHARP] = 1,  -- Oil of Sharpness (already valid in MP)
    [IMISC_OILDEATH] = 10, -- Oil of Death (missing in MP)
    [IMISC_OILSKILL] = 4,  -- Oil of Skill (missing in MP)
    [IMISC_OILBSMTH] = 1,  -- Blacksmith Oil (already valid in MP)
    [IMISC_OILFORT]  = 5,  -- Oil of Fortitude (already valid in MP)
    [IMISC_OILPERM]  = 17, -- Oil of Permanence (missing in MP)
    [IMISC_OILHARD]  = 1,  -- Oil of Hardening (missing in MP)
    [IMISC_OILIMP]   = 10  -- Oil of Imperviousness (missing in MP)
}

-- Oils that are already valid in multiplayer (should NOT be changed)
local ValidOilsInMP = {
    [IMISC_OILBSMTH] = true, -- Blacksmith Oil
    [IMISC_OILACC]   = true, -- Oil of Accuracy
    [IMISC_OILSHARP] = true, -- Oil of Sharpness
    [IMISC_OILFORT]  = true  -- Oil of Fortitude
}

-- Hook into oil generation
items.OnOilGenerate = function(item, maxLvl)
    -- If not in multiplayer, do nothing
    if not gbIsMultiplayer then
        return
    end

    -- If the oil is already valid in multiplayer, do NOT change it
    if ValidOilsInMP[item._iMiscId] then
        return
    end

    -- Apply CF_SINGLE flag to ensure item stability
    items.setItemFlag(item, CF_SINGLE)

    -- Build a list of missing oils that are valid for this maxLvl
    local availableOils = {}
    for miscId, requiredLvl in pairs(OilLevels) do
        if requiredLvl <= maxLvl and not ValidOilsInMP[miscId] then
            table.insert(availableOils, miscId)
        end
    end

    -- If we found valid missing oils, pick one at random
    if #availableOils > 0 then
        item._iMiscId = availableOils[math.random(#availableOils)]
    end
end
