-------------------------------------------------------------------------------
-- VaultGlance – Core.lua
-- Initialization, saved variables, vault data gathering, slash commands.
-- NOTE: SetFont needs 3 args in WoW 12.0.  _G singleton guard for frames.
-------------------------------------------------------------------------------
local ADDON_NAME, VP = ...

VP.version = "1.5.0"

-------------------------------------------------------------------------------
-- Defaults
-------------------------------------------------------------------------------
local DEFAULTS = {
    minimapBtn    = true,   -- show minimap button
    minimapAngle  = 225,    -- position around minimap (degrees)
    hoverSummary  = true,   -- show summary on minimap hover
    colorFullLine = false,  -- color the whole line vs just the difficulty
}

local CHAR_DEFAULTS = {
    delves       = {},          -- { { name="...", time=123456 }, ... }
    dungeons     = {},          -- { { name="...", level=12, time=123456 }, ... }
    dungeonDiffs = {},          -- { ["Instance Name"] = difficultyID (2=Heroic, 23=M0) }
    resetTime    = 0,           -- server time of next weekly reset when data was stored
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
end

-------------------------------------------------------------------------------
-- Vault snapshot — tracks activity levels so we can detect upgrades
-------------------------------------------------------------------------------
local vaultSnapshot = {}  -- { [activityID] = { level=N, ilvl=N, type=T, index=I } }

local function GetRewardIlvlForID(activityID)
    if not C_WeeklyRewards or not C_WeeklyRewards.GetExampleRewardItemHyperlinks then
        return nil
    end
    local link = C_WeeklyRewards.GetExampleRewardItemHyperlinks(activityID)
    if not link then return nil end
    local _, _, _, ilvl
    if C_Item and C_Item.GetItemInfo then
        _, _, _, ilvl = C_Item.GetItemInfo(link)
    elseif GetItemInfo then
        _, _, _, ilvl = GetItemInfo(link)
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

-------------------------------------------------------------------------------
-- Save current character's vault state to account-wide DB for alt viewing
-------------------------------------------------------------------------------
local function GetCharKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    if name and realm then return name .. "-" .. realm end
    return nil
end

local function SaveCharacterVault()
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
        dungeonNames = VP.chardb and VP.chardb.dungeons or {},
        delveNames   = VP.chardb and VP.chardb.delves or {},
        dungeonDiffs = VP.chardb and VP.chardb.dungeonDiffs or {},
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
    if GetNumSavedInstances then
        local diffRank = { Mythic = 4, Heroic = 3, Normal = 2, LFR = 1 }
        for i = 1, GetNumSavedInstances() do
            local _, _, _, difficultyID, locked, _, _, isRaid = GetSavedInstanceInfo(i)
            if isRaid and locked and GetSavedInstanceEncounterInfo then
                local diffName = DIFF_NAMES[difficultyID] or "?"
                local enc = 1
                while true do
                    local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, enc)
                    if not bossName then break end
                    if isKilled then
                        char.raids[#char.raids + 1] = {
                            boss = bossName,
                            difficulty = diffName,
                            rank = diffRank[diffName] or 0,
                        }
                    end
                    enc = enc + 1
                end
            end
        end
        table.sort(char.raids, function(a, b) return a.rank > b.rank end)
        -- Deduplicate: keep only highest difficulty per boss
        local seen = {}
        local unique = {}
        for _, k in ipairs(char.raids) do
            if not seen[k.boss] then
                seen[k.boss] = true
                unique[#unique + 1] = k
            end
        end
        char.raids = unique
    end

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
                    print(msg)
                end
            end
        end
    end

    -- Re-snapshot after comparison
    SnapshotVault()
    SaveCharacterVault()
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
        PruneStaleCharacters()
        -- Take initial vault snapshot after a short delay for data to load
        C_Timer.After(3, function() SnapshotVault() SaveCharacterVault() end)
        print(CLR_VP .. "VaultGlance|r v" .. VP.version .. " loaded. Type " .. CLR_VP .. "/vg help|r for commands.")

    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsureMapInfo()
        if RequestRaidInfo then RequestRaidInfo() end
        VP:CheckWeeklyReset()
        C_Timer.After(2, function()
            SnapshotVault()
            SaveCharacterVault()
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
            CheckVaultUpgrades()
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

    print(CLR_VP .. "VaultGlance|r Delve completed: " .. CLR_WHITE .. name .. "|r")

    if self.RefreshOverlay then self:RefreshOverlay() end
    SaveCharacterVault()
end

-------------------------------------------------------------------------------
-- Keystone completed (CHALLENGE_MODE_COMPLETED)
-------------------------------------------------------------------------------
function VP:OnKeystoneCompleted()
    EnsureMapInfo()
    local mapID, level
    if C_ChallengeMode and C_ChallengeMode.GetCompletionInfo then
        mapID, level = C_ChallengeMode.GetCompletionInfo()
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
    print(CLR_VP .. "VaultGlance|r Dungeon completed: " .. CLR_WHITE .. name .. "|r " .. kc .. kf .. "|r")

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

    print(CLR_VP .. "VaultGlance|r Dungeon completed: " .. CLR_WHITE .. name .. "|r")

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
        print(CLR_VP .. "VaultGlance|r Dungeon completed: " .. CLR_WHITE .. instanceName .. "|r " .. clr .. tag .. "|r")

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

    local diffName = DIFF_NAMES[difficultyID] or "?"
    local short = DIFF_SHORT[diffName] or "?"
    local clr = DIFF_CLR[diffName] or CLR_WHITE
    print(CLR_VP .. "VaultGlance|r Boss killed: " .. CLR_WHITE .. bossName .. "|r " .. clr .. short .. "|r")
    SaveCharacterVault()
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_VAULTGLANCE1 = "/vg"
SLASH_VAULTGLANCE2 = "/vaultglance"
SlashCmdList["VAULTGLANCE"] = function(msg)
    local cmd = (msg or ""):lower():trim()

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

    else
        print("|cFF00CCFFVaultGlance|r Commands:")
        print("  |cFF00CCFF/vg|r — Open/close Great Vault")
        print("  |cFF00CCFF/vg refresh|r — Force data refresh")
        print("  |cFF00CCFF/vg list|r — Print vault summary to chat")
        print("  |cFF00CCFF/vg help|r — Show this help")
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
    if GetNumSavedInstances then
        local diffRank = { Mythic = 4, Heroic = 3, Normal = 2, LFR = 1 }
        local kills = {}
        for i = 1, GetNumSavedInstances() do
            local _, _, _, diffID, locked, _, _, isRaid = GetSavedInstanceInfo(i)
            if isRaid and locked and GetSavedInstanceEncounterInfo then
                local diff = DIFF_NAMES[diffID] or "?"
                local short = DIFF_SHORT[diff] or "?"
                local clr = DIFF_CLR[diff] or CLR_WHITE
                local enc = 1
                while true do
                    local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, enc)
                    if not bossName then break end
                    if isKilled then
                        kills[#kills + 1] = { boss = bossName, short = short, clr = clr, rank = diffRank[diff] or 0 }
                    end
                    enc = enc + 1
                end
            end
        end
        table.sort(kills, function(a, b) return a.rank > b.rank end)
        local seen = {}
        for _, k in ipairs(kills) do
            if not seen[k.boss] then
                seen[k.boss] = true
                print("  " .. k.boss .. " " .. k.clr .. k.short .. "|r")
            end
        end
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

    -- Helper: get reward ilvl for an activity
    local function GetIlvl(activityID)
        if not C_WeeklyRewards or not C_WeeklyRewards.GetExampleRewardItemHyperlinks then return nil end
        local link = C_WeeklyRewards.GetExampleRewardItemHyperlinks(activityID)
        if not link then return nil end
        local _, _, _, ilvl
        if C_Item and C_Item.GetItemInfo then _, _, _, ilvl = C_Item.GetItemInfo(link)
        elseif GetItemInfo then _, _, _, ilvl = GetItemInfo(link) end
        return ilvl
    end

    local function SortActs(acts)
        local s = {}
        for i, a in ipairs(acts) do s[i] = a end
        table.sort(s, function(a, b) return a.threshold < b.threshold end)
        return s
    end

    local PREY_LABEL = { [1] = "N", [5] = "H", [8] = "NM" }


    -- RAIDS ------------------------------------------------------------------
    local rActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities(TYPE_RAID) or {}
    rActs = SortActs(rActs)
    local rProg, rMax = 0, 0
    for _, a in ipairs(rActs) do
        if a.progress > rProg then rProg = a.progress end
        if a.threshold > rMax then rMax = a.threshold end
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Raids", rProg .. "/" .. rMax, 0, 0.8, 1, 1, 1, 1)

    local kills = {}
    if GetNumSavedInstances then
        local diffRank = { Mythic = 4, Heroic = 3, Normal = 2, LFR = 1 }
        for i = 1, GetNumSavedInstances() do
            local _, _, _, difficultyID, locked, _, _, isRaid = GetSavedInstanceInfo(i)
            if isRaid and locked and GetSavedInstanceEncounterInfo then
                local diffName = GetDiffName(difficultyID)
                local enc = 1
                while true do
                    local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, enc)
                    if not bossName then break end
                    if isKilled then
                        kills[#kills + 1] = { boss = bossName, diff = diffName, rank = diffRank[diffName] or 0 }
                    end
                    enc = enc + 1
                end
            end
        end
        table.sort(kills, function(a, b) return a.rank > b.rank end)

        -- Deduplicate: keep only highest difficulty per boss
        local seen = {}
        local uniqueKills = {}
        for _, k in ipairs(kills) do
            if not seen[k.boss] then
                seen[k.boss] = true
                uniqueKills[#uniqueKills + 1] = k
            end
        end
        kills = uniqueKills
    end

    local rSlots = {}
    local rThresh = {}
    local rIlvlClr = {}
    for _, a in ipairs(rActs) do
        rSlots[a.threshold] = GetIlvl(a.id)
        rThresh[a.threshold] = true
        local dn = DIFF_NAMES[a.level] or "?"
        rIlvlClr[a.threshold] = DIFF_CLR[dn] or CLR_WHITE
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
        else
            tooltip:AddLine("  " .. line)
        end
    end

    -- DUNGEONS ---------------------------------------------------------------
    local dActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities(TYPE_MYTHICPLUS) or {}
    dActs = SortActs(dActs)
    local dProg, dMax = 0, 0
    for _, a in ipairs(dActs) do
        if a.progress > dProg then dProg = a.progress end
        if a.threshold > dMax then dMax = a.threshold end
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Dungeons", dProg .. "/" .. dMax, 0, 0.8, 1, 1, 1, 1)

    -- API run breakdown
    local dRuns = {}
    if #dActs > 0 then
        local lastAct = dActs[#dActs]
        local ok, tiers = pcall(C_WeeklyRewards.GetSortedProgressForActivity, 1, lastAct.id)
        if ok and tiers then
            for _, tp in ipairs(tiers) do
                for j = 1, (tp.numPoints or 0) do
                    dRuns[#dRuns + 1] = { level = tp.difficulty or 0 }
                end
            end
        end
    end
    table.sort(dRuns, function(a, b) return a.level > b.level end)

    -- Named runs from GetRunHistory + local
    EnsureMapInfo()
    local dNamed = {}
    local localDungeons = self.chardb and self.chardb.dungeons or {}
    for _, d in ipairs(localDungeons) do
        dNamed[#dNamed + 1] = { name = d.name, level = d.level or 0 }
    end
    if C_MythicPlus and C_MythicPlus.GetRunHistory then
        local rawRuns = C_MythicPlus.GetRunHistory(false, false) or {}
        for _, run in ipairs(rawRuns) do
            local name = nil
            if run.mapChallengeModeID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
                local n = C_ChallengeMode.GetMapUIInfo(run.mapChallengeModeID)
                if n and n ~= "" then name = n end
            end
            if name then dNamed[#dNamed + 1] = { name = name, level = run.level or 0 } end
        end
    end
    table.sort(dNamed, function(a, b) return a.level > b.level end)

    -- Merge names to API runs by level
    local dClaimed, dUsed = {}, {}
    for ni, nr in ipairs(dNamed) do
        for ai, ar in ipairs(dRuns) do
            if not dClaimed[ai] and not dUsed[ni] and ar.level == nr.level then
                dClaimed[ai] = ni; dUsed[ni] = true; break
            end
        end
    end

    -- Slot thresholds for ilvl separators — color by activityTierID
    local dSlots = {}
    local dThresh = {}
    local dIlvlClr = {}
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

    local dDiffs = self.chardb and self.chardb.dungeonDiffs or {}

    local dIdx = 0
    for ai, ar in ipairs(dRuns) do
        dIdx = dIdx + 1
        if dIdx > dMax then break end
        local kc = KeyColorChat(ar.level)
        local kf = KeyFmtChat(ar.level)
        local name = dClaimed[ai] and dNamed[dClaimed[ai]].name or nil

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
        else
            tooltip:AddLine("  " .. line)
        end
    end
    for i = dIdx + 1, dMax do
        if dThresh[i] then
            tooltip:AddDoubleLine("  " .. CLR_GREY .. "Locked|r", "")
        else
            tooltip:AddLine("  " .. CLR_GREY .. "-|r")
        end
    end

    -- WORLD/DELVES -----------------------------------------------------------
    local wActs = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities(TYPE_WORLD) or {}
    wActs = SortActs(wActs)
    local wProg, wMax = 0, 0
    for _, a in ipairs(wActs) do
        if a.progress > wProg then wProg = a.progress end
        if a.threshold > wMax then wMax = a.threshold end
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("World/Delves", wProg .. "/" .. wMax, 0, 0.8, 1, 1, 1, 1)

    local wRuns = {}
    if #wActs > 0 then
        local lastAct = wActs[#wActs]
        local ok, tiers = pcall(C_WeeklyRewards.GetSortedProgressForActivity, 6, lastAct.id)
        if ok and tiers then
            for _, tp in ipairs(tiers) do
                for j = 1, (tp.numPoints or 0) do
                    wRuns[#wRuns + 1] = { tier = tp.difficulty or 0 }
                end
            end
        end
    end
    table.sort(wRuns, function(a, b) return a.tier > b.tier end)

    local localDelves = self.chardb and self.chardb.delves or {}
    local sortedLocal = {}
    for i, d in ipairs(localDelves) do sortedLocal[i] = d end
    table.sort(sortedLocal, function(a, b) return (a.time or 0) > (b.time or 0) end)

    local wSlots = {}
    local wThresh = {}
    local wIlvlClr = {}
    for _, a in ipairs(wActs) do
        wSlots[a.threshold] = GetIlvl(a.id)
        wThresh[a.threshold] = true
        wIlvlClr[a.threshold] = DelveIlvlClrChat(a.level)
    end

    local localIdx = 1
    local wIdx = 0
    for _, ar in ipairs(wRuns) do
        wIdx = wIdx + 1
        if wIdx > wMax then break end
        local t = ar.tier
        local tc = DelveTierClrChat(t)
        local name = nil
        if localIdx <= #sortedLocal then
            name = sortedLocal[localIdx].name
            localIdx = localIdx + 1
        end
        local line
        if t >= 1 then
            if name then
                line = CLR_WHITE .. name .. "|r " .. tc .. "T" .. t .. "|r"
            else
                local prey = PREY_LABEL[t]
                if prey then
                    line = CLR_WHITE .. "Delve " .. "|r" .. tc .. "T" .. t .. "|r" .. CLR_WHITE .. " / Prey " .. "|r" .. tc .. prey .. "|r"
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
        else
            tooltip:AddLine("  " .. line)
        end
    end
    for i = wIdx + 1, wMax do
        if wThresh[i] then
            tooltip:AddDoubleLine("  " .. CLR_GREY .. "Locked|r", "")
        else
            tooltip:AddLine("  " .. CLR_GREY .. "-|r")
        end
    end

    tooltip:AddLine(" ")
    tooltip:AddLine("Click to open Great Vault", 0.5, 0.5, 0.5)
end
