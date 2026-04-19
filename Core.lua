-------------------------------------------------------------------------------
-- VaultGlance – Core.lua
-- Initialization, saved variables, vault data gathering, slash commands.
-- NOTE: SetFont needs 3 args in WoW 12.0.  _G singleton guard for frames.
-------------------------------------------------------------------------------
local ADDON_NAME, VP = ...

VP.version = "0.1.1"

-------------------------------------------------------------------------------
-- Defaults
-------------------------------------------------------------------------------
local DEFAULTS = {
    minimapBtn    = true,   -- show minimap button
    minimapAngle  = 225,    -- position around minimap (degrees)
    hoverSummary  = true,   -- show summary on minimap hover
    colorFullLine = false,  -- color the whole line vs just the difficulty
    compactMode   = false,  -- denser overlay rows
    notifyDungeons = true,  -- chat notice for dungeon completions
    notifyRaids    = true,  -- chat notice for raid boss kills
    notifyDelves   = true,  -- chat notice for delve completions
    notifyUpgrades = true,  -- chat notice for vault slot upgrades
}

local CHAR_DEFAULTS = {
    delves       = {},          -- { { name="...", time=123456 }, ... }
    dungeons     = {},          -- { { name="...", level=12, time=123456 }, ... }
    dungeonDiffs = {},          -- { ["Instance Name"] = difficultyID (2=Heroic, 23=M0) }
    resetTime    = 0,           -- server time of next weekly reset when data was stored
    rewardIlvls  = {},          -- { [activityID] = ilvl }
    rewardCacheResetTime = 0,   -- reset time associated with rewardIlvls
}

-------------------------------------------------------------------------------
-- Chat color helpers (shared across messages)
-------------------------------------------------------------------------------
local CLR_VP      = "|cFF00CCFF"   -- addon name
local CLR_WHITE   = "|cFFFFFFFF"
local CLR_EXPLORER= "|cFFFFFFFF"
local CLR_VETERAN = "|cFF1EFF00"
local CLR_CHAMPION= "|cFF3399FF"
local CLR_HERO    = "|cFFCC66FF"
local CLR_MYTH    = "|cFFFF8000"
local CLR_GOLD    = "|cFFFFD100"

local function KeyColorChat(lvl)
    if not lvl or lvl <= 0 then return CLR_EXPLORER end
    if lvl <= 1  then return CLR_VETERAN end
    if lvl <= 5  then return CLR_CHAMPION end
    if lvl <= 9  then return CLR_HERO end
    return CLR_MYTH
end

local function KeyFmtChat(lvl)
    if not lvl or lvl <= 0 then return "H" end
    return "+" .. lvl
end

local DIFF_NAMES = {
    [17]="LFR", [14]="Normal", [15]="Heroic", [16]="Mythic",
    [1]="LFR", [2]="Normal", [3]="Heroic", [4]="Mythic",
}
local DIFF_SHORT  = { LFR="RF", Normal="N", Heroic="H", Mythic="M" }
local DIFF_CLR    = { LFR=CLR_VETERAN, Normal=CLR_CHAMPION, Heroic=CLR_HERO, Mythic=CLR_MYTH }

local function DelveTierClrChat(t)
    if not t or t <= 1 then return CLR_EXPLORER end
    if t <= 4  then return CLR_VETERAN end
    if t <= 7  then return CLR_CHAMPION end
    if t <= 10 then return CLR_HERO end
    return CLR_MYTH
end

-- Ilvl color for delves — caps at purple since T8+ all give the same reward
local function DelveIlvlClrChat(t)
    if not t or t <= 1 then return CLR_EXPLORER end
    if t <= 4  then return CLR_VETERAN end
    if t <= 7  then return CLR_CHAMPION end
    return CLR_HERO
end

-------------------------------------------------------------------------------
-- Ensure C_MythicPlus data is loaded
-------------------------------------------------------------------------------
local mapInfoRequested = false
local function EnsureMapInfo()
    if not mapInfoRequested and C_MythicPlus and C_MythicPlus.RequestMapInfo then
        C_MythicPlus.RequestMapInfo()
        mapInfoRequested = true
    end
end

local function DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do
        copy[DeepCopy(k, seen)] = DeepCopy(v, seen)
    end
    return copy
end

local function Trim(text)
    text = text or ""
    if strtrim then return strtrim(text) end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local unpackArgs = unpack or table.unpack
local EnsureRewardCache
local SaveCharacterVault

-------------------------------------------------------------------------------
-- WEEKLY RESET DETECTION
-------------------------------------------------------------------------------
function VP:CheckWeeklyReset()
    local cdb = self.chardb
    if not cdb then return end

    local now = GetServerTime()
    if cdb.resetTime > 0 and now >= cdb.resetTime then
        wipe(cdb.delves)
        if cdb.dungeons then wipe(cdb.dungeons) end
        if cdb.dungeonDiffs then wipe(cdb.dungeonDiffs) end
        if cdb.rewardIlvls then wipe(cdb.rewardIlvls) end
        cdb.rewardCacheResetTime = 0
        cdb.resetTime = 0
        print(CLR_VP .. "VaultGlance|r Weekly reset detected — local history cleared.")
    end

    -- Compute the next reset time and store it
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local secsUntil = C_DateAndTime.GetSecondsUntilWeeklyReset()
        if secsUntil and secsUntil > 0 then
            cdb.resetTime = now + secsUntil
        end
    end
    EnsureRewardCache()
end

-------------------------------------------------------------------------------
-- Vault snapshot — tracks activity levels so we can detect upgrades
-------------------------------------------------------------------------------
local vaultSnapshot = {}  -- { [activityID] = { level=N, ilvl=N, type=T, index=I } }
local worldTierSnapshot = {}
local NOTIFY_KEYS = {
    dungeon = "notifyDungeons",
    raid = "notifyRaids",
    delve = "notifyDelves",
    upgrade = "notifyUpgrades",
}

EnsureRewardCache = function()
    local cdb = VP and VP.chardb
    if not cdb then return nil end
    cdb.rewardIlvls = cdb.rewardIlvls or {}

    local resetTime = cdb.resetTime or 0
    if (cdb.rewardCacheResetTime or 0) ~= resetTime then
        wipe(cdb.rewardIlvls)
        cdb.rewardCacheResetTime = resetTime
    end

    return cdb.rewardIlvls
end

local function InvalidateRewardCache(activityID)
    local cache = EnsureRewardCache()
    if not cache then return end

    if activityID ~= nil then
        cache[activityID] = nil
    else
        wipe(cache)
    end
end

local function GetRewardIlvlForID(activityID)
    if not C_WeeklyRewards or not C_WeeklyRewards.GetExampleRewardItemHyperlinks then
        return nil
    end
    local cache = EnsureRewardCache()
    if cache and cache[activityID] then
        return cache[activityID]
    end
    local link = C_WeeklyRewards.GetExampleRewardItemHyperlinks(activityID)
    if not link then return nil end
    local _, _, _, ilvl
    if C_Item and C_Item.GetItemInfo then
        _, _, _, ilvl = C_Item.GetItemInfo(link)
    elseif GetItemInfo then
        _, _, _, ilvl = GetItemInfo(link)
    end
    if ilvl and cache then
        cache[activityID] = ilvl
    end
    return ilvl
end

local function SnapshotVault()
    if not C_WeeklyRewards or not C_WeeklyRewards.GetActivities then return end
    wipe(vaultSnapshot)
    for _, t in ipairs({1, 3, 6}) do
        local acts = C_WeeklyRewards.GetActivities(t)
        if acts then
            for _, a in ipairs(acts) do
                vaultSnapshot[a.id] = {
                    level = a.level or 0,
                    type  = t,
                    index = a.index or 0,
                    ilvl  = GetRewardIlvlForID(a.id),
                }
            end
        end
    end
end

local function CopyCountMap(src)
    local copy = {}
    for k, v in pairs(src or {}) do
        copy[k] = v
    end
    return copy
end

local function SortActivities(acts)
    local sorted = {}
    for i, a in ipairs(acts or {}) do sorted[i] = a end
    table.sort(sorted, function(a, b)
        if a.threshold ~= b.threshold then return a.threshold < b.threshold end
        return (a.index or 0) < (b.index or 0)
    end)
    return sorted
end

local function GetHighestThresholdActivity(acts)
    local best = nil
    for _, a in ipairs(acts or {}) do
        if not best or (a.threshold or 0) > (best.threshold or 0) then
            best = a
        end
    end
    return best
end

local function GetTierCountsForActivity(activityType, acts)
    local counts = {}
    if not C_WeeklyRewards or not C_WeeklyRewards.GetSortedProgressForActivity then
        return counts
    end

    local lastAct = GetHighestThresholdActivity(acts)
    if not lastAct then return counts end

    local ok, tierList = pcall(C_WeeklyRewards.GetSortedProgressForActivity, activityType, lastAct.id)
    if not ok or not tierList then return counts end

    for _, tp in ipairs(tierList) do
        local difficulty = tp.difficulty or 0
        local numPoints = tp.numPoints or 0
        counts[difficulty] = (counts[difficulty] or 0) + numPoints
    end

    return counts
end

local function SnapshotWorldTiers()
    local acts = {}
    if C_WeeklyRewards and C_WeeklyRewards.GetActivities then
        acts = SortActivities(C_WeeklyRewards.GetActivities(6) or {})
    end
    worldTierSnapshot = CopyCountMap(GetTierCountsForActivity(6, acts))
end

local function BuildDungeonApiRuns(activities)
    local apiRuns = {}
    local lastAct = GetHighestThresholdActivity(activities)
    if lastAct and C_WeeklyRewards and C_WeeklyRewards.GetSortedProgressForActivity then
        local ok, tiers = pcall(C_WeeklyRewards.GetSortedProgressForActivity, 1, lastAct.id)
        if ok and tiers then
            for _, tp in ipairs(tiers) do
                local lvl = tp.difficulty or 0
                local count = tp.numPoints or 0
                for _ = 1, count do
                    apiRuns[#apiRuns + 1] = { level = lvl }
                end
            end
        end
    end

    if #apiRuns == 0 and C_MythicPlus and C_MythicPlus.GetRunHistory then
        EnsureMapInfo()
        local rawRuns = C_MythicPlus.GetRunHistory(false, false) or {}
        for _, run in ipairs(rawRuns) do
            apiRuns[#apiRuns + 1] = { level = run.level or 0 }
        end
    end

    table.sort(apiRuns, function(a, b) return (a.level or 0) > (b.level or 0) end)
    return apiRuns
end

local function MakeDungeonRunKey(name, level)
    return tostring(name or "") .. "\031" .. tostring(level or 0)
end

local function ParseDungeonRunKey(key)
    local name, level = tostring(key):match("^(.*)\031(.*)$")
    return name or "", tonumber(level) or 0
end

local function BuildNamedDungeonRuns()
    local namedRuns = {}
    local localCounts = {}
    local historyCounts = {}

    local localDungeons = VP.chardb and VP.chardb.dungeons or {}
    for _, d in ipairs(localDungeons) do
        if d and d.name and d.name ~= "" then
            local level = d.level or 0
            namedRuns[#namedRuns + 1] = { name = d.name, level = level }
            local key = MakeDungeonRunKey(d.name, level)
            localCounts[key] = (localCounts[key] or 0) + 1
        end
    end

    if C_MythicPlus and C_MythicPlus.GetRunHistory then
        EnsureMapInfo()
        local rawRuns = C_MythicPlus.GetRunHistory(false, false) or {}
        for _, run in ipairs(rawRuns) do
            local name = nil
            if run.mapChallengeModeID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
                local n = C_ChallengeMode.GetMapUIInfo(run.mapChallengeModeID)
                if n and n ~= "" then name = n end
            end
            if name then
                local key = MakeDungeonRunKey(name, run.level or 0)
                local entry = historyCounts[key]
                if not entry then
                    entry = { name = name, level = run.level or 0, count = 0 }
                    historyCounts[key] = entry
                end
                entry.count = entry.count + 1
            end
        end
    end

    for key, entry in pairs(historyCounts) do
        local localCount = localCounts[key] or 0
        local extra = entry.count - localCount
        local name, level = ParseDungeonRunKey(key)
        for _ = 1, math.max(0, extra) do
            namedRuns[#namedRuns + 1] = { name = name, level = level }
        end
    end

    return namedRuns
end

local function DungeonDiffSortRank(namedRun, dungeonDiffs)
    if (namedRun.level or 0) > 0 then return 0 end
    local diff = namedRun.name and dungeonDiffs[namedRun.name]
    if diff == 23 then return 0 end
    if not diff then return 1 end
    return 2
end

local function BuildMergedDungeonRuns(activities)
    local apiRuns = BuildDungeonApiRuns(activities)
    local namedRuns = BuildNamedDungeonRuns()
    local dungeonDiffs = VP.chardb and VP.chardb.dungeonDiffs or {}

    table.sort(namedRuns, function(a, b)
        local aLevel = a.level or 0
        local bLevel = b.level or 0
        if aLevel ~= bLevel then return aLevel > bLevel end
        local ra = DungeonDiffSortRank(a, dungeonDiffs)
        local rb = DungeonDiffSortRank(b, dungeonDiffs)
        if ra ~= rb then return ra < rb end
        return (a.name or "") < (b.name or "")
    end)

    local apiClaimed = {}
    local namedUsed = {}

    for ni, nr in ipairs(namedRuns) do
        for ai, ar in ipairs(apiRuns) do
            if not apiClaimed[ai] and not namedUsed[ni] and (ar.level or 0) == (nr.level or 0) then
                apiClaimed[ai] = ni
                namedUsed[ni] = true
                break
            end
        end
    end

    for ni, _ in ipairs(namedRuns) do
        if not namedUsed[ni] then
            for ai, _ in ipairs(apiRuns) do
                if not apiClaimed[ai] then
                    apiClaimed[ai] = ni
                    namedUsed[ni] = true
                    break
                end
            end
        end
    end

    local merged = {}
    for ai, ar in ipairs(apiRuns) do
        local name = nil
        if apiClaimed[ai] and namedRuns[apiClaimed[ai]] then
            name = namedRuns[apiClaimed[ai]].name
        end
        merged[#merged + 1] = {
            name = name,
            level = ar.level or 0,
        }
    end

    return merged
end

local function GetTooltipLeftLines(tooltip)
    local lines = {}
    if not tooltip or not tooltip.IsShown or not tooltip:IsShown() then
        return lines
    end

    local numLines = tooltip:NumLines() or 0
    for i = 1, numLines do
        local fs = _G[tooltip:GetName() .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text ~= "" then
            lines[#lines + 1] = text
        end
    end

    return lines
end

local function ParseDungeonRunsFromTooltipLines(lines)
    local runs = {}
    local inRunsSection = false

    for _, rawLine in ipairs(lines or {}) do
        local line = Trim(rawLine)
        if line:find("^Top%s+%d+%s+Runs%s+This%s+Week") then
            inRunsSection = true
        elseif inRunsSection then
            local level, name = line:match("^%+?(%d+)%s*%-%s*(.+)$")
            if level and name and name ~= "" then
                runs[#runs + 1] = {
                    level = tonumber(level) or 0,
                    name = name,
                }
            elseif #runs > 0 then
                break
            end
        end
    end

    return runs
end

local function ReadDungeonRunsFromVaultTooltip()
    if not GameTooltip then
        return nil, {}
    end

    local lines = GetTooltipLeftLines(GameTooltip)
    local runs = ParseDungeonRunsFromTooltipLines(lines)
    if #runs > 0 then
        return runs, lines
    end

    return nil, lines
end

local function ImportDungeonRunsFromVaultTooltip(runs)
    if not VP.chardb then
        return 0, 0
    end

    VP.chardb.dungeons = VP.chardb.dungeons or {}

    local replaced = 0
    local added = 0

    for _, run in ipairs(runs or {}) do
        local matched = false

        for i = #VP.chardb.dungeons, 1, -1 do
            local d = VP.chardb.dungeons[i]
            if d
                and (d.name == "Unknown Dungeon" or d.name == nil or d.name == "")
                and (d.level or 0) == (run.level or 0) then
                d.name = run.name
                matched = true
                replaced = replaced + 1
                break
            end
        end

        if not matched then
            local exists = false
            for _, d in ipairs(VP.chardb.dungeons) do
                if d and d.name == run.name and (d.level or 0) == (run.level or 0) then
                    exists = true
                    break
                end
            end

            if not exists then
                VP.chardb.dungeons[#VP.chardb.dungeons + 1] = {
                    name = run.name,
                    level = run.level or 0,
                    time = GetServerTime(),
                }
                added = added + 1
            end
        end
    end

    return replaced, added
end

local function ProcessVaultTooltipDungeonRuns(verbose)
    local runs, lines = ReadDungeonRunsFromVaultTooltip()
    if not runs or #runs == 0 then
        if verbose then
            print(CLR_VP .. "VaultGlance|r No dungeon runs found in the current tooltip.")
            if lines and #lines > 0 then
                print(CLR_VP .. "VaultGlance|r Tooltip lines seen:")
                for _, line in ipairs(lines) do
                    print("  " .. line)
                end
            end
        end
        return 0, 0, lines
    end

    if verbose then
        print(CLR_VP .. "VaultGlance|r Parsed dungeon runs from current tooltip:")
        for _, run in ipairs(runs) do
            print(string.format("  +%d - %s", run.level or 0, run.name or "Unknown"))
        end
    end

    local replaced, added = ImportDungeonRunsFromVaultTooltip(runs)
    if replaced > 0 or added > 0 then
        if verbose then
            print(CLR_VP .. "VaultGlance|r Updated local dungeon names: replaced " .. replaced .. ", added " .. added .. ".")
        else
            print(CLR_VP .. "VaultGlance|r Imported dungeon name(s) from the Great Vault tooltip.")
        end
        if VP and VP.RefreshOverlay then VP:RefreshOverlay() end
        SaveCharacterVault()
    end

    return replaced, added, lines
end

function VaultGlance_ReadVaultTooltip()
    ProcessVaultTooltipDungeonRuns(true)
end

local function HasUnknownDungeonRuns()
    local acts = C_WeeklyRewards and C_WeeklyRewards.GetActivities and SortActivities(C_WeeklyRewards.GetActivities(1) or {}) or {}
    if #acts == 0 then
        return false
    end

    local runs = VP.GetMergedDungeonRuns and VP:GetMergedDungeonRuns(acts) or {}
    for _, run in ipairs(runs) do
        if not run.name or run.name == "" or run.name == "Unknown Dungeon" then
            return true
        end
    end

    return false
end

local tooltipScannerHooked = false
local tooltipScanPending = false

local function HookAutomaticVaultTooltipScan()
    if tooltipScannerHooked or not GameTooltip then
        return
    end

    GameTooltip:HookScript("OnShow", function()
        if tooltipScanPending then
            return
        end

        tooltipScanPending = true
        C_Timer.After(0, function()
            tooltipScanPending = false
            if not WeeklyRewardsFrame or not WeeklyRewardsFrame:IsShown() then
                return
            end
            if not HasUnknownDungeonRuns() then
                return
            end
            ProcessVaultTooltipDungeonRuns(false)
        end)
    end)

    tooltipScannerHooked = true
end

local function BuildWorldApiRuns(activities)
    local apiRuns = {}
    local lastAct = GetHighestThresholdActivity(activities)
    if lastAct and C_WeeklyRewards and C_WeeklyRewards.GetSortedProgressForActivity then
        local ok, tierList = pcall(C_WeeklyRewards.GetSortedProgressForActivity, 6, lastAct.id)
        if ok and tierList then
            for _, tp in ipairs(tierList) do
                local tier = tp.difficulty or 0
                local count = tp.numPoints or 0
                for _ = 1, count do
                    apiRuns[#apiRuns + 1] = { tier = tier }
                end
            end
        end
    end

    table.sort(apiRuns, function(a, b) return (a.tier or 0) > (b.tier or 0) end)
    return apiRuns
end

local function BuildWorldThresholdRewards(activities)
    local sortedActs = SortActivities(activities or {})
    local apiRuns = BuildWorldApiRuns(sortedActs)
    local thresholds = {}
    local unlockedIlvls = {}

    for _, a in ipairs(sortedActs) do
        if (a.level or 0) > 0 then
            local ilvl = GetRewardIlvlForID(a.id)
            if ilvl then
                unlockedIlvls[#unlockedIlvls + 1] = ilvl
            end
        end
    end

    table.sort(unlockedIlvls, function(a, b) return (a or 0) > (b or 0) end)

    local rewardIdx = 1
    for _, a in ipairs(sortedActs) do
        local slotTier = (apiRuns[a.threshold] and apiRuns[a.threshold].tier) or 0
        local rewardIlvl = nil
        if slotTier > 0 and rewardIdx <= #unlockedIlvls then
            rewardIlvl = unlockedIlvls[rewardIdx]
            rewardIdx = rewardIdx + 1
        end

        thresholds[#thresholds + 1] = {
            at = a.threshold,
            level = (slotTier > 0) and slotTier or (a.level or 0),
            ilvl = rewardIlvl,
        }
    end

    return thresholds
end

local function BuildMergedWorldRuns(activities)
    local apiRuns = BuildWorldApiRuns(activities)
    local namedByTier = {}
    local namedIndex = {}

    local localDelves = VP.chardb and VP.chardb.delves or {}
    for _, d in ipairs(localDelves) do
        if d and d.name and d.name ~= "" and d.tier and d.tier > 0 then
            namedByTier[d.tier] = namedByTier[d.tier] or {}
            namedByTier[d.tier][#namedByTier[d.tier] + 1] = {
                name = d.name,
                time = d.time or 0,
            }
        end
    end

    for _, bucket in pairs(namedByTier) do
        table.sort(bucket, function(a, b) return (a.time or 0) > (b.time or 0) end)
    end

    local merged = {}
    for _, ar in ipairs(apiRuns) do
        local tier = ar.tier or 0
        local bucket = namedByTier[tier]
        local idx = namedIndex[tier] or 1
        local name = nil
        if bucket and bucket[idx] then
            name = bucket[idx].name
            namedIndex[tier] = idx + 1
        end
        merged[#merged + 1] = {
            name = name,
            tier = tier,
        }
    end

    return merged
end

local RAID_DIFF_RANK = { Mythic = 4, Heroic = 3, Normal = 2, LFR = 1 }
local currentRaidBossOrder = nil
local currentRaidBossOrderReady = false

local function GetRaidDifficultyName(difficultyID)
    return DIFF_NAMES[difficultyID] or (GetDifficultyInfo and GetDifficultyInfo(difficultyID)) or "?"
end

local function GetCurrentRaidBossOrder()
    if currentRaidBossOrderReady then
        return currentRaidBossOrder
    end
    currentRaidBossOrderReady = true

    if not (EJ_GetCurrentTier and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_SelectInstance and EJ_GetEncounterInfoByIndex) then
        if C_AddOns and C_AddOns.LoadAddOn then
            pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal")
        elseif LoadAddOn then
            pcall(LoadAddOn, "Blizzard_EncounterJournal")
        end
    end

    if not (EJ_GetCurrentTier and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_SelectInstance and EJ_GetEncounterInfoByIndex) then
        return nil
    end

    local tier = EJ_GetCurrentTier and EJ_GetCurrentTier()
    if not tier then
        return nil
    end

    pcall(EJ_SelectTier, tier)

    local journalInstanceID = nil
    for idx = 1, 20 do
        local _, _, instanceID = EJ_GetInstanceByIndex(idx, true)
        if not instanceID then break end
        journalInstanceID = instanceID
        break
    end
    if not journalInstanceID then
        return nil
    end

    pcall(EJ_SelectInstance, journalInstanceID)

    local bosses = {}
    for idx = 1, 20 do
        local bossName = EJ_GetEncounterInfoByIndex(idx, journalInstanceID)
        if not bossName then break end
        bosses[bossName] = idx
    end

    if next(bosses) then
        currentRaidBossOrder = bosses
    end

    return currentRaidBossOrder
end

local function BuildCurrentRaidKills()
    local kills = {}
    if not GetNumSavedInstances or not GetSavedInstanceInfo or not GetSavedInstanceEncounterInfo then
        return kills
    end

    local bossOrder = GetCurrentRaidBossOrder()

    for i = 1, GetNumSavedInstances() do
        local _, _, _, difficultyID, locked, _, _, isRaid = GetSavedInstanceInfo(i)
        if isRaid and locked then
            local diffName = GetRaidDifficultyName(difficultyID)
            local enc = 1
            while true do
                local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, enc)
                if not bossName then break end
                if isKilled and (not bossOrder or bossOrder[bossName]) then
                    kills[#kills + 1] = {
                        boss = bossName,
                        difficulty = diffName,
                        diff = diffName,
                        diffID = difficultyID,
                        rank = RAID_DIFF_RANK[diffName] or 0,
                        encOrder = (bossOrder and bossOrder[bossName]) or enc,
                    }
                end
                enc = enc + 1
            end
        end
    end

    table.sort(kills, function(a, b)
        local oa, ob = a.rank or 0, b.rank or 0
        if oa ~= ob then return oa > ob end
        return (a.encOrder or 0) < (b.encOrder or 0)
    end)

    local seen = {}
    local uniqueKills = {}
    for _, k in ipairs(kills) do
        if not seen[k.boss] then
            seen[k.boss] = true
            uniqueKills[#uniqueKills + 1] = k
        end
    end

    return uniqueKills
end

-------------------------------------------------------------------------------
-- Save current character's vault state to account-wide DB for alt viewing
-------------------------------------------------------------------------------
local function GetCharKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    if name and realm then return name .. "-" .. realm end
    return nil
end

SaveCharacterVault = function()
    if not VP.db or not C_WeeklyRewards or not C_WeeklyRewards.GetActivities then return end
    local key = GetCharKey()
    if not key then return end

    if not VP.db.characters then VP.db.characters = {} end

    local char = {
        name     = UnitName("player"),
        realm    = GetRealmName(),
        class    = select(2, UnitClass("player")),
        level    = UnitLevel("player"),
        time     = GetServerTime(),
        activities = {},   -- { [type] = { { index, threshold, progress, level, activityTierID, ilvl }, ... } }
        tiers    = {},     -- { [type] = { { difficulty, numPoints, activityTierID }, ... } }
        raids    = {},     -- { { boss, difficulty, rank }, ... }
        dungeonNames = DeepCopy(VP.chardb and VP.chardb.dungeons or {}),
        delveNames   = DeepCopy(VP.chardb and VP.chardb.delves or {}),
        dungeonDiffs = DeepCopy(VP.chardb and VP.chardb.dungeonDiffs or {}),
    }

    -- Activities per type
    for _, t in ipairs({1, 3, 6}) do
        char.activities[t] = {}
        local acts = C_WeeklyRewards.GetActivities(t)
        if acts then
            for _, a in ipairs(acts) do
                char.activities[t][#char.activities[t] + 1] = {
                    index = a.index or 0,
                    threshold = a.threshold or 0,
                    progress = a.progress or 0,
                    level = a.level or 0,
                    activityTierID = a.activityTierID or 0,
                    id = a.id,
                    ilvl = GetRewardIlvlForID(a.id),
                }
            end
            table.sort(char.activities[t], function(a, b) return a.threshold < b.threshold end)
        end

        -- Tier breakdowns for dungeons and delves
        if t == 1 or t == 6 then
            char.tiers[t] = {}
            if acts and #acts > 0 then
                local lastAct = acts[1]
                for _, a in ipairs(acts) do
                    if a.threshold > lastAct.threshold then lastAct = a end
                end
                local ok, tierList = pcall(C_WeeklyRewards.GetSortedProgressForActivity, t, lastAct.id)
                if ok and tierList then
                    for _, tp in ipairs(tierList) do
                        char.tiers[t][#char.tiers[t] + 1] = {
                            difficulty = tp.difficulty or 0,
                            numPoints = tp.numPoints or 0,
                            activityTierID = tp.activityTierID or 0,
                        }
                    end
                end
            end
        end
    end

    -- Raid kills
    char.raids = BuildCurrentRaidKills()

    VP.db.characters[key] = char
end

local PRUNE_AGE = 14 * 24 * 60 * 60  -- 2 weeks in seconds

local function PruneStaleCharacters()
    if not VP.db or not VP.db.characters then return end
    local now = GetServerTime()
    local pruned = {}
    for key, char in pairs(VP.db.characters) do
        if char.time and (now - char.time) > PRUNE_AGE then
            pruned[#pruned + 1] = key
        end
    end
    for _, key in ipairs(pruned) do
        VP.db.characters[key] = nil
    end
end

local TYPE_LABELS = { [1] = "Dungeon", [3] = "Raid", [6] = "World/Delve" }

local function CheckVaultUpgrades()
    if not C_WeeklyRewards or not C_WeeklyRewards.GetActivities then return end

    for _, t in ipairs({1, 3, 6}) do
        local acts = C_WeeklyRewards.GetActivities(t)
        if acts then
            for _, a in ipairs(acts) do
                local old = vaultSnapshot[a.id]
                local newLevel = a.level or 0
                if old and newLevel > old.level and newLevel > 0 then
                    local newIlvl = GetRewardIlvlForID(a.id)
                    local label = TYPE_LABELS[t] or "Activity"
                    local slotStr = label .. " slot " .. (a.index or "?")

                    -- Build colored level string
                    local lvlStr
                    if t == 1 then
                        lvlStr = KeyColorChat(newLevel) .. KeyFmtChat(newLevel) .. "|r"
                    elseif t == 3 then
                        local dn = DIFF_NAMES[newLevel] or "?"
                        local ds = DIFF_SHORT[dn] or "?"
                        local dc = DIFF_CLR[dn] or CLR_WHITE
                        lvlStr = dc .. ds .. "|r"
                    elseif t == 6 then
                        lvlStr = DelveTierClrChat(newLevel) .. "T" .. newLevel .. "|r"
                    else
                        lvlStr = CLR_WHITE .. tostring(newLevel) .. "|r"
                    end

                    local msg = CLR_VP .. "VaultGlance|r " .. slotStr .. " upgraded to " .. lvlStr
                    if newIlvl then
                        msg = msg .. " — reward " .. CLR_GOLD .. newIlvl .. " ilvl|r"
                    end
                    VP:Notify("upgrade", msg)
                end
            end
        end
    end

    -- Re-snapshot after comparison
    SnapshotVault()
    SaveCharacterVault()
end

function VP:GetRewardIlvl(activityID)
    return GetRewardIlvlForID(activityID)
end

function VP:Notify(kind, msg)
    local key = NOTIFY_KEYS[kind]
    if not key or not self.db or self.db[key] ~= false then
        print(msg)
    end
end

function VP:GetSortedActivities(acts)
    return SortActivities(acts)
end

function VP:GetMergedDungeonRuns(activities)
    return BuildMergedDungeonRuns(activities or {})
end

function VP:GetMergedWorldRuns(activities)
    return BuildMergedWorldRuns(activities or {})
end

function VP:GetWorldThresholdRewards(activities)
    return BuildWorldThresholdRewards(activities or {})
end

function VP:GetCurrentRaidKills()
    return BuildCurrentRaidKills()
end

function VP:IsCurrentRaidBoss(bossName)
    local bossOrder = GetCurrentRaidBossOrder()
    return (not bossOrder) or bossOrder[bossName] ~= nil
end

function VP:GetPendingDelveCount()
    local count = 0
    local delves = self.chardb and self.chardb.delves or {}
    for _, delve in ipairs(delves) do
        if delve and delve.name and delve.name ~= "" and not delve.tier then
            count = count + 1
        end
    end
    return count
end

function VP:ResolvePendingDelves()
    if not self.chardb or not self.chardb.delves then
        SnapshotWorldTiers()
        return false
    end

    local acts = {}
    if C_WeeklyRewards and C_WeeklyRewards.GetActivities then
        acts = SortActivities(C_WeeklyRewards.GetActivities(6) or {})
    end
    local currentCounts = GetTierCountsForActivity(6, acts)

    local pending = {}
    for idx, delve in ipairs(self.chardb.delves) do
        if delve and delve.name and delve.name ~= "" and not delve.tier then
            pending[#pending + 1] = { index = idx, time = delve.time or 0 }
        end
    end

    if #pending == 0 then
        worldTierSnapshot = CopyCountMap(currentCounts)
        return false
    end

    local gainedTiers = {}
    for tier, count in pairs(currentCounts) do
        local delta = count - (worldTierSnapshot[tier] or 0)
        for _ = 1, math.max(0, delta) do
            gainedTiers[#gainedTiers + 1] = tier
        end
    end

    table.sort(pending, function(a, b) return (a.time or 0) < (b.time or 0) end)
    table.sort(gainedTiers, function(a, b) return a > b end)

    local assigned = false
    if #pending == 1 and #gainedTiers == 1 then
        self.chardb.delves[pending[1].index].tier = gainedTiers[1]
        assigned = true
    elseif #pending > 0 and #pending == #gainedTiers then
        local sameTier = true
        for i = 2, #gainedTiers do
            if gainedTiers[i] ~= gainedTiers[1] then
                sameTier = false
                break
            end
        end
        if sameTier then
            for _, item in ipairs(pending) do
                self.chardb.delves[item.index].tier = gainedTiers[1]
            end
            assigned = true
        end
    end

    worldTierSnapshot = CopyCountMap(currentCounts)

    if assigned then
        SaveCharacterVault()
    end

    return assigned
end

local settingsCategoryFrame = nil
local settingsCategory = nil

local function MakeSettingsCheckbox(parent, anchor, label, getState, setState)
    local btn = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    btn:SetPoint(unpackArgs(anchor))

    local text = btn.Text or btn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    if not btn.Text then
        text:SetPoint("LEFT", btn, "RIGHT", 4, 0)
        btn.Text = text
    end
    text:SetText(label)

    btn:SetScript("OnClick", function(self)
        setState(self:GetChecked())
    end)

    function btn:Sync()
        self:SetChecked(getState() and true or false)
    end

    btn:Sync()
    return btn
end

function VP:OpenSettings()
    if settingsCategory and Settings and Settings.OpenToCategory and settingsCategory.GetID then
        local ok = pcall(function()
            Settings.OpenToCategory(settingsCategory:GetID())
        end)
        if ok then return end
    end

    if InterfaceOptionsFrame_OpenToCategory and settingsCategoryFrame then
        InterfaceOptionsFrame_OpenToCategory(settingsCategoryFrame)
        InterfaceOptionsFrame_OpenToCategory(settingsCategoryFrame)
    end
end

function VP:RegisterSettingsPanel()
    if settingsCategoryFrame or not self.db then return end

    local panel = CreateFrame("Frame", "VaultGlanceSettingsPanel", UIParent)
    panel.name = "VaultGlance"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("VaultGlance")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetWidth(620)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetJustifyV("TOP")
    subtitle:SetText("Great Vault overlay, minimap tooltip, local completion tracking, and notification preferences.")

    local toggles = {}
    local specs = {
        { label = "Show minimap button", key = "minimapBtn", onChange = function() VP:UpdateMinimapButton() end },
        { label = "Show minimap hover summary", key = "hoverSummary" },
        { label = "Color full entry line", key = "colorFullLine", onChange = function() if VP.RefreshOverlay then VP:RefreshOverlay() end end },
        { label = "Compact overlay mode", key = "compactMode", onChange = function() if VP.RefreshOverlay then VP:RefreshOverlay() end end },
        { label = "Notify for dungeon completions", key = "notifyDungeons" },
        { label = "Notify for raid boss kills", key = "notifyRaids" },
        { label = "Notify for delve completions", key = "notifyDelves" },
        { label = "Notify for vault upgrades", key = "notifyUpgrades" },
    }

    local previous = nil
    for idx, spec in ipairs(specs) do
        local anchor
        if idx == 1 then
            anchor = { "TOPLEFT", panel, "TOPLEFT", 16, -70 }
        else
            anchor = { "TOPLEFT", previous, "BOTTOMLEFT", 0, -6 }
        end

        local checkbox = MakeSettingsCheckbox(panel, anchor, spec.label,
            function()
                return VP.db and VP.db[spec.key]
            end,
            function(value)
                if VP.db then
                    VP.db[spec.key] = value and true or false
                    if spec.onChange then spec.onChange() end
                end
            end
        )
        toggles[#toggles + 1] = checkbox
        previous = checkbox
    end

    panel:SetScript("OnShow", function()
        for _, checkbox in ipairs(toggles) do
            checkbox:Sync()
        end
    end)

    settingsCategoryFrame = panel

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, category = pcall(function()
            return Settings.RegisterCanvasLayoutCategory(panel, "VaultGlance")
        end)
        if ok and category then
            settingsCategory = category
            pcall(function()
                Settings.RegisterAddOnCategory(category)
            end)
            return
        end
    end
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
initFrame:RegisterEvent("WEEKLY_REWARDS_UPDATE")
initFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
initFrame:RegisterEvent("SCENARIO_COMPLETED")
initFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
initFrame:RegisterEvent("BOSS_KILL")
initFrame:RegisterEvent("LFG_COMPLETION_REWARD")
initFrame:RegisterEvent("ENCOUNTER_END")
initFrame:SetScript("OnEvent", function(_, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        VaultGlanceDB = VaultGlanceDB or {}
        for k, v in pairs(DEFAULTS) do
            if VaultGlanceDB[k] == nil then VaultGlanceDB[k] = v end
        end
        VP.db = VaultGlanceDB

        VaultGlanceCharDB = VaultGlanceCharDB or {}
        for k, v in pairs(CHAR_DEFAULTS) do
            if VaultGlanceCharDB[k] == nil then
                VaultGlanceCharDB[k] = type(v) == "table" and {} or v
            end
        end
        VP.chardb = VaultGlanceCharDB

    elseif event == "PLAYER_LOGIN" then
        EnsureMapInfo()
        if RequestRaidInfo then RequestRaidInfo() end
        VP:CheckWeeklyReset()
        InvalidateRewardCache()
        HookAutomaticVaultTooltipScan()
        PruneStaleCharacters()
        VP:RegisterSettingsPanel()
        -- Take initial vault snapshot after a short delay for data to load
        C_Timer.After(3, function()
            SnapshotVault()
            SaveCharacterVault()
            SnapshotWorldTiers()
        end)
        print(CLR_VP .. "VaultGlance|r v" .. VP.version .. " loaded. Type " .. CLR_VP .. "/vg help|r for commands.")

    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsureMapInfo()
        if RequestRaidInfo then RequestRaidInfo() end
        VP:CheckWeeklyReset()
        C_Timer.After(2, function()
            SnapshotVault()
            SaveCharacterVault()
            SnapshotWorldTiers()
            if VP.RefreshOverlay then VP:RefreshOverlay() end
        end)

    elseif event == "SCENARIO_COMPLETED" then
        VP:OnScenarioCompleted()

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        VP:OnKeystoneCompleted()

    elseif event == "BOSS_KILL" then
        local bossID = arg1
        local bossName = ...
        VP:OnBossKill(bossName)

    elseif event == "LFG_COMPLETION_REWARD" then
        VP:OnDungeonFinderComplete()

    elseif event == "ENCOUNTER_END" then
        -- args: encounterID, encounterName, difficultyID, groupSize, success
        local encounterID = arg1
        local encounterName, difficultyID, groupSize, success = ...
        if success == 1 then
            VP:OnEncounterEnd(encounterID, encounterName, difficultyID)
        end

    elseif event == "WEEKLY_REWARDS_UPDATE" then
        -- Delay slightly to let API update, then check for upgrades
        C_Timer.After(0.5, function()
            InvalidateRewardCache()
            CheckVaultUpgrades()
            VP:ResolvePendingDelves()
            if VP.RefreshOverlay then VP:RefreshOverlay() end
        end)

    elseif event == "CHALLENGE_MODE_MAPS_UPDATE"
        or event == "UPDATE_INSTANCE_INFO" then
        if VP.RefreshOverlay then VP:RefreshOverlay() end
    end
end)

-------------------------------------------------------------------------------
-- Delve auto-detection via SCENARIO_COMPLETED
-- Detects delve completions by checking GetInstanceInfo for scenario type
-- with a delve-range difficultyID (200-250) or matching a known delve name.
-------------------------------------------------------------------------------
local DELVE_DIFF_MIN = 200
local DELVE_DIFF_MAX = 250

function VP:OnScenarioCompleted()
    local name, instanceType, difficultyID = GetInstanceInfo()
    if not name or instanceType ~= "scenario" then return end

    -- Check if this is a delve (difficultyID in delve range)
    if not difficultyID or difficultyID < DELVE_DIFF_MIN or difficultyID > DELVE_DIFF_MAX then
        return
    end

    -- Store name locally — tier comes from vault API
    if not self.chardb then return end
    if not self.chardb.delves then self.chardb.delves = {} end
    self.chardb.delves[#self.chardb.delves + 1] = {
        name = name,
        time = GetServerTime(),
    }

    self:Notify("delve", CLR_VP .. "VaultGlance|r Delve completed: " .. CLR_WHITE .. name .. "|r")

    if self.RefreshOverlay then self:RefreshOverlay() end
    SaveCharacterVault()
    C_Timer.After(1, function()
        if VP:ResolvePendingDelves() and VP.RefreshOverlay then
            VP:RefreshOverlay()
        end
    end)
end

-------------------------------------------------------------------------------
-- Keystone completed (CHALLENGE_MODE_COMPLETED)
-------------------------------------------------------------------------------
local function GetChallengeCompletionMapAndLevel()
    if not C_ChallengeMode then
        return nil, nil
    end

    if C_ChallengeMode.GetChallengeCompletionInfo then
        local info = C_ChallengeMode.GetChallengeCompletionInfo()
        if info then
            return info.mapChallengeModeID, info.level
        end
    end

    if C_ChallengeMode.GetCompletionInfo then
        return C_ChallengeMode.GetCompletionInfo()
    end

    return nil, nil
end

function VP:OnKeystoneCompleted(retryCount)
    EnsureMapInfo()
    local mapID, level = GetChallengeCompletionMapAndLevel()
    if (not mapID or mapID == 0) and (retryCount or 0) < 2 and C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            VP:OnKeystoneCompleted((retryCount or 0) + 1)
        end)
        return
    end

    local name = "Unknown Dungeon"
    if mapID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
        local n = C_ChallengeMode.GetMapUIInfo(mapID)
        if n and n ~= "" then name = n end
    end

    local lvl = level or 0

    -- Store name locally — level is accurate from GetCompletionInfo
    if not self.chardb then return end
    if not self.chardb.dungeons then self.chardb.dungeons = {} end
    self.chardb.dungeons[#self.chardb.dungeons + 1] = {
        name = name,
        level = lvl,
        time = GetServerTime(),
    }

    local kc = KeyColorChat(lvl)
    local kf = KeyFmtChat(lvl)
    self:Notify("dungeon", CLR_VP .. "VaultGlance|r Dungeon completed: " .. CLR_WHITE .. name .. "|r " .. kc .. kf .. "|r")

    if self.RefreshOverlay then self:RefreshOverlay() end
    SaveCharacterVault()
end

-------------------------------------------------------------------------------
-- Heroic/Mythic dungeon completion (LFG_COMPLETION_REWARD)
-------------------------------------------------------------------------------
function VP:OnDungeonFinderComplete()
    local name, instanceType = GetInstanceInfo()
    if not name or instanceType ~= "party" then return end

    -- Store name locally — level comes from vault API
    if not self.chardb then return end
    if not self.chardb.dungeons then self.chardb.dungeons = {} end
    self.chardb.dungeons[#self.chardb.dungeons + 1] = {
        name = name,
        time = GetServerTime(),
    }

    self:Notify("dungeon", CLR_VP .. "VaultGlance|r Dungeon completed: " .. CLR_WHITE .. name .. "|r")

    if self.RefreshOverlay then self:RefreshOverlay() end
    SaveCharacterVault()
end

-------------------------------------------------------------------------------
-- Encounter end — used to detect Heroic vs M0 dungeon difficulty
-- ENCOUNTER_END args: encounterID, encounterName, difficultyID, groupSize, success
-- difficultyID 2 = Heroic, 23 = M0
-------------------------------------------------------------------------------
local DUNGEON_DIFF_HEROIC = 2
local DUNGEON_DIFF_M0     = 23

function VP:OnEncounterEnd(encounterID, encounterName, difficultyID)
    -- Only care about party dungeons (Heroic or M0)
    if difficultyID ~= DUNGEON_DIFF_HEROIC and difficultyID ~= DUNGEON_DIFF_M0 then return end

    local instanceName = GetInstanceInfo()
    if not instanceName then return end

    -- Store the difficulty for this dungeon name so the overlay can distinguish H vs M0
    if not self.chardb then return end
    if not self.chardb.dungeonDiffs then self.chardb.dungeonDiffs = {} end
    self.chardb.dungeonDiffs[instanceName] = difficultyID

    -- Also store the dungeon name locally if we don't have it yet this session
    if not self.chardb.dungeons then self.chardb.dungeons = {} end
    -- Check if we already have this dungeon stored recently (within 5 min)
    local now = GetServerTime()
    local isDuplicate = false
    for i = #self.chardb.dungeons, math.max(1, #self.chardb.dungeons - 5), -1 do
        local d = self.chardb.dungeons[i]
        if d and d.name == instanceName and d.time and (now - d.time) < 300 then
            -- Update existing entry with diffID
            d.diffID = difficultyID
            isDuplicate = true
            break
        end
    end

    if not isDuplicate then
        self.chardb.dungeons[#self.chardb.dungeons + 1] = {
            name = instanceName,
            diffID = difficultyID,
            time = now,
        }

        local isHeroic = (difficultyID == DUNGEON_DIFF_HEROIC)
        local tag = isHeroic and "H" or "M0"
        local clr = isHeroic and CLR_EXPLORER or CLR_VETERAN
        self:Notify("dungeon", CLR_VP .. "VaultGlance|r Dungeon completed: " .. CLR_WHITE .. instanceName .. "|r " .. clr .. tag .. "|r")

        if self.RefreshOverlay then self:RefreshOverlay() end
        SaveCharacterVault()
    else
        if self.RefreshOverlay then self:RefreshOverlay() end
        SaveCharacterVault()
    end
end

-------------------------------------------------------------------------------
-- Raid boss killed (BOSS_KILL)
-------------------------------------------------------------------------------
function VP:OnBossKill(bossName)
    if not bossName then return end

    -- Only report if we're in a raid
    local _, instanceType, difficultyID = GetInstanceInfo()
    if instanceType ~= "raid" then return end
    if not self:IsCurrentRaidBoss(bossName) then return end

    local diffName = DIFF_NAMES[difficultyID] or "?"
    local short = DIFF_SHORT[diffName] or "?"
    local clr = DIFF_CLR[diffName] or CLR_WHITE
    self:Notify("raid", CLR_VP .. "VaultGlance|r Boss killed: " .. CLR_WHITE .. bossName .. "|r " .. clr .. short .. "|r")
    SaveCharacterVault()
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_VAULTGLANCE1 = "/vg"
SLASH_VAULTGLANCE2 = "/vaultglance"
SlashCmdList["VAULTGLANCE"] = function(msg)
    local cmd = Trim((msg or ""):lower())

    if cmd == "" then
        -- Open/close the vault
        if not WeeklyRewardsFrame then
            C_AddOns.LoadAddOn("Blizzard_WeeklyRewards")
        end
        if WeeklyRewardsFrame then
            if WeeklyRewardsFrame:IsShown() then
                WeeklyRewardsFrame:Hide()
            else
                WeeklyRewardsFrame:Show()
            end
        end

    elseif cmd == "refresh" then
        EnsureMapInfo()
        if RequestRaidInfo then RequestRaidInfo() end
        if VP.RefreshOverlay then VP:RefreshOverlay() end
        print(CLR_VP .. "VaultGlance|r Refreshed.")

    elseif cmd == "list" then
        VP:PrintSummary()

    elseif cmd == "debug" then
        VP:PrintDebug()

    elseif cmd == "scan" or cmd == "tooltip" then
        VaultGlance_ReadVaultTooltip()

    elseif cmd == "settings" or cmd == "options" then
        VP:OpenSettings()

    else
        print("|cFF00CCFFVaultGlance|r Commands:")
        print("  |cFF00CCFF/vg debug|r - Print raw addon tracking data")
        print("  |cFF00CCFF/vg scan|r - Read dungeon names from the current tooltip")
        print("  |cFF00CCFF/vg settings|r - Open addon settings")
        print("  |cFF00CCFF/vg|r — Open/close Great Vault")
        print("  |cFF00CCFF/vg refresh|r — Force data refresh")
        print("  |cFF00CCFF/vg list|r — Print vault summary to chat")
        print("  |cFF00CCFF/vg help|r — Show this help")
    end
end

function VP:PrintDebug()
    local pendingDelves = self:GetPendingDelveCount()
    local cache = EnsureRewardCache() or {}
    local cacheCount = 0
    for _ in pairs(cache) do cacheCount = cacheCount + 1 end

    print(CLR_GOLD .. "--- VaultGlance Debug ---|r")
    print("Reset time: " .. tostring(self.chardb and self.chardb.resetTime or 0))
    print("Pending delve names: " .. tostring(pendingDelves))
    print("Reward ilvl cache entries: " .. tostring(cacheCount))

    for _, t in ipairs({ 1, 3, 6 }) do
        local acts = C_WeeklyRewards and C_WeeklyRewards.GetActivities and SortActivities(C_WeeklyRewards.GetActivities(t) or {}) or {}
        local label = TYPE_LABELS[t] or tostring(t)
        print(CLR_VP .. label .. "|r slots:")
        for _, a in ipairs(acts) do
            print(string.format("  slot=%s threshold=%s progress=%s level=%s tierID=%s ilvl=%s",
                tostring(a.index or "?"),
                tostring(a.threshold or 0),
                tostring(a.progress or 0),
                tostring(a.level or 0),
                tostring(a.activityTierID or 0),
                tostring(self:GetRewardIlvl(a.id) or "nil")
            ))
        end
    end

    local dActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and SortActivities(C_WeeklyRewards.GetActivities(1) or {}) or {}
    local dRuns = self:GetMergedDungeonRuns(dActs)
    print(CLR_VP .. "Dungeon merged runs|r:")
    for i = 1, math.min(#dRuns, 12) do
        local run = dRuns[i]
        print(string.format("  %d. %s (%s)", i, tostring(run.name or "Dungeon"), tostring(run.level or 0)))
    end

    local wActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and SortActivities(C_WeeklyRewards.GetActivities(6) or {}) or {}
    local wRuns = self:GetMergedWorldRuns(wActs)
    print(CLR_VP .. "World merged runs|r:")
    for i = 1, math.min(#wRuns, 12) do
        local run = wRuns[i]
        print(string.format("  %d. %s (T%s)", i, tostring(run.name or "Delve"), tostring(run.tier or 0)))
    end
end

function VP:PrintSummary()
    local TYPE_M = 1
    local TYPE_R = 3
    local TYPE_W = 6

    print(CLR_GOLD .. "--- VaultGlance Summary ---|r")

    -- Dungeons
    local dProg, dMax = 0, 0
    if C_WeeklyRewards and C_WeeklyRewards.GetActivities then
        local acts = C_WeeklyRewards.GetActivities(TYPE_M)
        if acts then
            for _, a in ipairs(acts) do
                if a.progress > dProg then dProg = a.progress end
                if a.threshold > dMax then dMax = a.threshold end
            end
        end
    end
    print(CLR_VP .. "Dungeons|r " .. dProg .. "/" .. dMax)
    EnsureMapInfo()
    if C_MythicPlus and C_MythicPlus.GetRunHistory then
        local runs = C_MythicPlus.GetRunHistory(false, false) or {}
        table.sort(runs, function(a, b) return (a.level or 0) > (b.level or 0) end)
        for i = 1, math.min(#runs, 8) do
            local name = "Unknown"
            if runs[i].mapChallengeModeID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
                local n = C_ChallengeMode.GetMapUIInfo(runs[i].mapChallengeModeID)
                if n and n ~= "" then name = n end
            end
            local lvl = runs[i].level or 0
            print("  " .. KeyColorChat(lvl) .. KeyFmtChat(lvl) .. "|r " .. name)
        end
    end

    -- Raids
    local rProg, rMax = 0, 0
    if C_WeeklyRewards and C_WeeklyRewards.GetActivities then
        local acts = C_WeeklyRewards.GetActivities(TYPE_R)
        if acts then
            for _, a in ipairs(acts) do
                if a.progress > rProg then rProg = a.progress end
                if a.threshold > rMax then rMax = a.threshold end
            end
        end
    end
    print(CLR_VP .. "Raids|r " .. rProg .. "/" .. rMax)
    for _, k in ipairs(self:GetCurrentRaidKills()) do
        local short = DIFF_SHORT[k.diff or k.difficulty] or "?"
        local clr = DIFF_CLR[k.diff or k.difficulty] or CLR_WHITE
        print("  " .. k.boss .. " " .. clr .. short .. "|r")
    end

    -- World/Delves
    local wProg, wMax = 0, 0
    if C_WeeklyRewards and C_WeeklyRewards.GetActivities then
        local acts = C_WeeklyRewards.GetActivities(TYPE_W)
        if acts then
            for _, a in ipairs(acts) do
                if a.progress > wProg then wProg = a.progress end
                if a.threshold > wMax then wMax = a.threshold end
            end
        end
    end
    print(CLR_VP .. "World/Delves|r " .. wProg .. "/" .. wMax)
    if C_WeeklyRewards and C_WeeklyRewards.GetSortedProgressForActivity then
        local acts = C_WeeklyRewards.GetActivities(TYPE_W)
        if acts then
            local lastAct = nil
            for _, a in ipairs(acts) do
                if not lastAct or a.threshold > lastAct.threshold then lastAct = a end
            end
            if lastAct then
                local ok, tiers = pcall(C_WeeklyRewards.GetSortedProgressForActivity, 6, lastAct.id)
                if ok and tiers then
                    for _, tp in ipairs(tiers) do
                        local t = tp.difficulty or 0
                        print("  " .. DelveTierClrChat(t) .. "T" .. t .. "|r x" .. (tp.numPoints or 0))
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Build summary lines for minimap hover tooltip
-- Returns a table of { text, r, g, b } or { left, right, lr, lg, lb, rr, rg, rb }
-------------------------------------------------------------------------------
local TYPE_MYTHICPLUS = 1
local TYPE_WORLD      = 6
local TYPE_RAID       = 3

local function GetDiffName(level)
    if DIFF_NAMES[level] then return DIFF_NAMES[level] end
    if GetDifficultyInfo then
        local name = GetDifficultyInfo(level)
        if name and name ~= "" then return name end
    end
    return "Diff" .. tostring(level)
end

function VP:PopulateSummaryTooltip(tooltip)
    tooltip:AddLine("VaultGlance", 1, 0.82, 0)

    local CLR_GREY = "|cFF666666"
    local function GetUnlockedSlotSummary(acts)
        local total = math.max(#(acts or {}), 3)
        local unlocked = 0
        for _, a in ipairs(acts or {}) do
            if (a.progress or 0) >= (a.threshold or 0) then
                unlocked = unlocked + 1
            end
        end
        return unlocked, total
    end

    -- Helper: get reward ilvl for an activity
    local function GetIlvl(activityID)
        return VP:GetRewardIlvl(activityID)
    end

    local PREY_LABEL = { [1] = "N", [5] = "H", [8] = "NM" }


    -- RAIDS ------------------------------------------------------------------
    local rActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities(TYPE_RAID) or {}
    rActs = SortActivities(rActs)
    local rProg, rMax = 0, 0
    for _, a in ipairs(rActs) do
        if a.progress > rProg then rProg = a.progress end
        if a.threshold > rMax then rMax = a.threshold end
    end
    local rUnlocked, rTotalSlots = GetUnlockedSlotSummary(rActs)
    local rRightR, rRightG, rRightB = 1, 1, 1
    if rUnlocked >= rTotalSlots and rTotalSlots > 0 then
        rRightR, rRightG, rRightB = 0, 1, 0
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Raids", rUnlocked .. "/" .. rTotalSlots .. " Unlocked", 0, 0.8, 1, rRightR, rRightG, rRightB)

    local kills = self.GetCurrentRaidKills and self:GetCurrentRaidKills() or {}

    local rSlots = {}
    local rThresh = {}
    local rIlvlClr = {}
    local rProgress = {}
    for _, a in ipairs(rActs) do
        rSlots[a.threshold] = GetIlvl(a.id)
        rThresh[a.threshold] = true
        local dn = DIFF_NAMES[a.level] or "?"
        rIlvlClr[a.threshold] = DIFF_CLR[dn] or CLR_WHITE
        rProgress[a.threshold] = string.format("%d/%d", rProg or 0, a.threshold or 0)
    end
    for i = 1, rMax do
        local line
        if i <= #kills then
            local k = kills[i]
            local dc = DIFF_CLR[k.diff] or CLR_WHITE
            local ds = DIFF_SHORT[k.diff] or "?"
            line = CLR_WHITE .. k.boss .. "|r " .. dc .. ds .. "|r"
        else
            local isThreshold = rThresh[i]
            line = CLR_GREY .. (isThreshold and "Locked" or "-") .. "|r"
        end
        if rSlots[i] then
            local ic = rIlvlClr[i] or CLR_GOLD
            tooltip:AddDoubleLine("  " .. line, ic .. rSlots[i] .. " ilvl|r")
        elseif rThresh[i] and rProgress[i] then
            tooltip:AddDoubleLine("  " .. line, CLR_GREY .. rProgress[i] .. "|r")
        else
            tooltip:AddLine("  " .. line)
        end
    end

    -- DUNGEONS ---------------------------------------------------------------
    local dActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities(TYPE_MYTHICPLUS) or {}
    dActs = SortActivities(dActs)
    local dProg, dMax = 0, 0
    for _, a in ipairs(dActs) do
        if a.progress > dProg then dProg = a.progress end
        if a.threshold > dMax then dMax = a.threshold end
    end
    local dUnlocked, dTotalSlots = GetUnlockedSlotSummary(dActs)
    local dRightR, dRightG, dRightB = 1, 1, 1
    if dUnlocked >= dTotalSlots and dTotalSlots > 0 then
        dRightR, dRightG, dRightB = 0, 1, 0
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Dungeons", dUnlocked .. "/" .. dTotalSlots .. " Unlocked", 0, 0.8, 1, dRightR, dRightG, dRightB)
    local dDiffs = self.chardb and self.chardb.dungeonDiffs or {}
    local dRuns = self:GetMergedDungeonRuns(dActs)

    -- Slot thresholds for ilvl separators — color by activityTierID
    local dSlots = {}
    local dThresh = {}
    local dIlvlClr = {}
    local dProgress = {}
    for _, a in ipairs(dActs) do
        dSlots[a.threshold] = GetIlvl(a.id)
        dThresh[a.threshold] = true
        if a.level > 0 then
            dIlvlClr[a.threshold] = KeyColorChat(a.level)
        elseif a.activityTierID == 102 then
            dIlvlClr[a.threshold] = CLR_VETERAN   -- M0 = green
        elseif a.activityTierID == 101 then
            dIlvlClr[a.threshold] = CLR_EXPLORER   -- Heroic = white
        else
            dIlvlClr[a.threshold] = CLR_EXPLORER
        end
        dProgress[a.threshold] = string.format("%d/%d", dProg or 0, a.threshold or 0)
    end

    -- M0/HC cutoffs from ilvl
    local ILVL_M0 = 256
    local m0Cutoff = 0
    local hcCutoff = dMax + 1
    for _, a in ipairs(dActs) do
        local ilvl = dSlots[a.threshold]
        if ilvl then
            if ilvl >= ILVL_M0 then
                if a.threshold > m0Cutoff then m0Cutoff = a.threshold end
            else
                if a.threshold < hcCutoff then hcCutoff = a.threshold end
            end
        end
    end

    local dIdx = 0
    for _, ar in ipairs(dRuns) do
        dIdx = dIdx + 1
        if dIdx > dMax then break end
        local kc = KeyColorChat(ar.level)
        local kf = KeyFmtChat(ar.level)
        local name = ar.name

        -- For level-0, determine H vs M0
        local state = nil
        if ar.level <= 0 then
            if name and dDiffs[name] then
                if dDiffs[name] == 23 then
                    state = "m0"
                else
                    state = "hc"
                end
            elseif dIdx <= m0Cutoff then
                state = "m0"
            elseif dIdx >= hcCutoff then
                state = "hc"
            else
                state = "ambiguous"
            end
        end

        if state == "m0" then
            kc = CLR_VETERAN; kf = "M0"
        elseif state == "hc" then
            kc = CLR_EXPLORER; kf = "HC"
        end

        local line
        if state == "ambiguous" then
            local tag = CLR_EXPLORER .. "HC|r" .. CLR_WHITE .. " / " .. "|r" .. CLR_VETERAN .. "M0|r"
            if name then
                line = CLR_WHITE .. name .. "|r " .. tag
            else
                line = CLR_WHITE .. "Dungeon" .. "|r " .. tag
            end
        elseif name then
            line = CLR_WHITE .. name .. "|r " .. kc .. kf .. "|r"
        else
            line = CLR_WHITE .. "Dungeon" .. "|r " .. kc .. kf .. "|r"
        end
        if dSlots[dIdx] then
            local ic = dIlvlClr[dIdx] or CLR_GOLD
            tooltip:AddDoubleLine("  " .. line, ic .. dSlots[dIdx] .. " ilvl|r")
        elseif dThresh[dIdx] and dProgress[dIdx] then
            tooltip:AddDoubleLine("  " .. line, CLR_GREY .. dProgress[dIdx] .. "|r")
        else
            tooltip:AddLine("  " .. line)
        end
    end
    for i = dIdx + 1, dMax do
        if dThresh[i] then
            tooltip:AddDoubleLine("  " .. CLR_GREY .. "Locked|r", CLR_GREY .. (dProgress[i] or "") .. "|r")
        else
            tooltip:AddLine("  " .. CLR_GREY .. "-|r")
        end
    end

    -- WORLD/DELVES -----------------------------------------------------------
    local wActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities(TYPE_WORLD) or {}
    wActs = SortActivities(wActs)
    local wProg, wMax = 0, 0
    for _, a in ipairs(wActs) do
        if a.progress > wProg then wProg = a.progress end
        if a.threshold > wMax then wMax = a.threshold end
    end
    local wUnlocked, wTotalSlots = GetUnlockedSlotSummary(wActs)
    local wRightR, wRightG, wRightB = 1, 1, 1
    if wUnlocked >= wTotalSlots and wTotalSlots > 0 then
        wRightR, wRightG, wRightB = 0, 1, 0
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("World/Delves", wUnlocked .. "/" .. wTotalSlots .. " Unlocked", 0, 0.8, 1, wRightR, wRightG, wRightB)
    local wRuns = self:GetMergedWorldRuns(wActs)
    local worldThresholds = self.GetWorldThresholdRewards and self:GetWorldThresholdRewards(wActs) or {}
    local wSlots = {}
    local wThresh = {}
    local wIlvlClr = {}
    local wProgress = {}
    for _, t in ipairs(worldThresholds) do
        wSlots[t.at] = t.ilvl
        wThresh[t.at] = true
        wIlvlClr[t.at] = DelveIlvlClrChat(t.level)
        wProgress[t.at] = string.format("%d/%d", wProg or 0, t.at or 0)
    end

    local wIdx = 0
    for _, ar in ipairs(wRuns) do
        wIdx = wIdx + 1
        if wIdx > wMax then break end
        local t = ar.tier
        local tc = DelveTierClrChat(t)
        local name = ar.name
        local line
        if t >= 1 then
            if name then
                line = CLR_WHITE .. name .. "|r " .. tc .. "T" .. t .. "|r"
            else
                local prey = PREY_LABEL[t]
                if prey then
            line = CLR_WHITE .. "Delve " .. "|r" .. tc .. "T" .. t .. "|r" .. CLR_WHITE .. " / Prey " .. "|r" .. tc .. prey .. "|r" .. ((t == 1) and (CLR_WHITE .. " / World|r") or "")
                else
                    line = CLR_WHITE .. "Delve" .. "|r " .. tc .. "T" .. t .. "|r"
                end
            end
        else
            line = CLR_VETERAN .. (name or "World Activity") .. "|r"
        end
        if wSlots[wIdx] then
            local ic = wIlvlClr[wIdx] or CLR_GOLD
            tooltip:AddDoubleLine("  " .. line, ic .. wSlots[wIdx] .. " ilvl|r")
        elseif wThresh[wIdx] and wProgress[wIdx] then
            tooltip:AddDoubleLine("  " .. line, CLR_GREY .. wProgress[wIdx] .. "|r")
        else
            tooltip:AddLine("  " .. line)
        end
    end
    for i = wIdx + 1, wMax do
        if wThresh[i] then
            tooltip:AddDoubleLine("  " .. CLR_GREY .. "Locked|r", CLR_GREY .. (wProgress[i] or "") .. "|r")
        else
            tooltip:AddLine("  " .. CLR_GREY .. "-|r")
        end
    end

    tooltip:AddLine(" ")
    tooltip:AddLine("Click to open Great Vault", 0.5, 0.5, 0.5)
end
