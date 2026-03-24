-------------------------------------------------------------------------------
-- VaultGlance – Overlay.lua
-- Three overlay panels on the Great Vault window, one per row
-- (Dungeons, Raids, World+Delves).
--
-- Each panel shows a vertical list of completed activities growing downward.
-- Horizontal separator lines mark where each vault slot unlocks.
--
-- Layout per panel (example: Dungeons with thresholds 1/4/8):
--
--   Cinderbrew Meadery +12
--   ──────────────── Slot 1 ────────────────
--   Darkflame Cleft +10
--   Operation: Floodgate +9
--   Priory of the Sacred Flame +8
--   ──────────────── Slot 2 ────────────────
--   -
--   -
--   -
--   -
--   ──────────────── Slot 3 ────────────────
--
-- WeeklyRewardsFrame is load-on-demand (Blizzard_WeeklyRewards).
-- NOTE: SetFont requires 3 args in WoW 12.0.  _G singleton guard.
-------------------------------------------------------------------------------
local _, VP = ...

local FONT_FILE    = "Fonts\\FRIZQT__.TTF"
local FONT_SIZE    = 10
local LINE_HEIGHT  = 13
local SEP_HEIGHT   = 6
local PANEL_WIDTH  = 210
local PANEL_PAD    = 6
local PANEL_ALPHA  = 0.88

local overlayReady = false

local TYPE_MYTHICPLUS = 1
local TYPE_WORLD      = 6
local TYPE_RAID       = 3

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function MakeFont(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT_FILE, size, "")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetJustifyV("MIDDLE")
    fs:SetWordWrap(false)
    return fs
end

-------------------------------------------------------------------------------
-- Color constants — mapped to gear track colors
-------------------------------------------------------------------------------
local CLR = {
    COMPLETE   = "|cFF00FF00",
    UNCOMPLETE = "|cFF666666",
    WHITE      = "|cFFFFFFFF",
    SLOT_LABEL = "|cFFFFD100",
    WORLD_DONE = "|cFF00FF00",
    -- Gear track colors
    EXPLORER   = "|cFFFFFFFF",   -- white (Adventurer/Explorer)
    VETERAN    = "|cFF1EFF00",   -- green (Veteran)
    CHAMPION   = "|cFF3399FF",   -- blue (Champion) — brightened
    HERO       = "|cFFCC66FF",   -- purple (Hero) — brightened
    MYTH       = "|cFFFF8000",   -- orange (Myth)
}

-- Short diff labels + color for raids
local DIFF_SHORT = {
    LFR    = { label = "RF",  color = CLR.VETERAN   },
    Normal = { label = "N",   color = CLR.CHAMPION   },
    Heroic = { label = "H",   color = CLR.HERO      },
    Mythic = { label = "M",   color = CLR.MYTH      },
}

local function DiffColor(diff)
    local d = DIFF_SHORT[diff]
    return d and d.color or CLR.WHITE
end

local function DiffShort(diff)
    local d = DIFF_SHORT[diff]
    return d and d.label or "?"
end

-- Key level color for M+ dungeons
local function KeyColor(level)
    if not level or level <= 0 then return CLR.EXPLORER end    -- Heroic
    if level <= 1  then return CLR.VETERAN end                 -- M0 (level 1 from API means no key)
    if level <= 5  then return CLR.CHAMPION end                -- +2 to +5
    if level <= 9  then return CLR.HERO end                    -- +6 to +9
    return CLR.MYTH                                            -- +10+
end

-- Format dungeon key level: H or +X
local function FormatKeyLevel(level)
    if not level or level <= 0 then return "H" end
    return "+" .. level
end

-- Delve tier color (display)
local function DelveTierColor(tier)
    if not tier or tier <= 1 then return CLR.EXPLORER end
    if tier <= 4  then return CLR.VETERAN end
    if tier <= 7  then return CLR.CHAMPION end
    if tier <= 10 then return CLR.HERO end
    return CLR.MYTH
end

-- Delve ilvl color — caps at purple since T8+ give same reward
local function DelveIlvlColor(tier)
    if not tier or tier <= 1 then return CLR.EXPLORER end
    if tier <= 4  then return CLR.VETERAN end
    if tier <= 7  then return CLR.CHAMPION end
    return CLR.HERO
end

local MAX_NAME_LEN = 25
local function TruncName(name)
    if not name then return "" end
    if #name <= MAX_NAME_LEN then return name end
    -- Find the last space that fits within the limit
    local cut = name:sub(1, MAX_NAME_LEN)
    local lastSpace = cut:match("^.*() ")
    if lastSpace and lastSpace > 1 then
        return cut:sub(1, lastSpace - 1) .. "..."
    end
    -- Single long word with no spaces — hard cut
    return cut:gsub(" +$", "") .. "..."
end

-------------------------------------------------------------------------------
-- PANEL OBJECT
-------------------------------------------------------------------------------
local MAX_ROWS = 20
local MAX_SEPS = 5

local function CreatePanel(name, parent)
    local panel = CreateFrame("Frame", name, parent, "BackdropTemplate")
    panel:SetWidth(PANEL_WIDTH)
    panel:SetHeight(50)
    panel:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    panel:SetBackdropColor(0.03, 0.03, 0.08, PANEL_ALPHA)
    panel:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.6)
    panel:SetFrameLevel(parent:GetFrameLevel() + 15)

    panel.rows = {}
    for i = 1, MAX_ROWS do
        local fs = MakeFont(panel, FONT_SIZE, "LEFT")
        fs:SetWidth(PANEL_WIDTH - PANEL_PAD * 2)
        fs:SetHeight(LINE_HEIGHT)
        fs:Hide()
        panel.rows[i] = fs
    end

    panel.seps = {}
    for i = 1, MAX_SEPS do
        local line = panel:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.6, 0.5, 0.2, 0.7)
        line:SetHeight(1)
        line:SetWidth(PANEL_WIDTH - PANEL_PAD * 2)
        line:Hide()
        panel.seps[i] = line
    end

    -- Right-aligned reward ilvl labels (one per separator/slot)
    panel.rewardLabels = {}
    for i = 1, MAX_SEPS do
        local fs = MakeFont(panel, FONT_SIZE, "RIGHT")
        fs:SetWidth(50)
        fs:SetHeight(LINE_HEIGHT)
        fs:Hide()
        panel.rewardLabels[i] = fs
    end

    -- Overflow indicator (+X) — anchored bottom-right, hidden by default
    local overflowBtn = CreateFrame("Button", nil, panel)
    overflowBtn:SetSize(30, 14)
    overflowBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 3)

    local overflowText = MakeFont(overflowBtn, 9, "RIGHT")
    overflowText:SetAllPoints()
    overflowBtn.label = overflowText
    overflowBtn.tooltipLines = {}

    overflowBtn:SetScript("OnEnter", function(self)
        if #self.tooltipLines == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Remaining bosses:", 1, 0.82, 0, true)
        for _, line in ipairs(self.tooltipLines) do
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    overflowBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    overflowBtn:Hide()
    panel.overflowBtn = overflowBtn

    return panel
end

-------------------------------------------------------------------------------
-- Populate a panel.
-- entries: { { text = "..." }, ... }
-- thresholds: { { at = N }, ... }  (separator after N entries)
-------------------------------------------------------------------------------
local function PopulatePanel(panel, entries, thresholds)
    for i = 1, MAX_ROWS do panel.rows[i]:Hide() end
    for i = 1, MAX_SEPS do panel.seps[i]:Hide() end
    for i = 1, MAX_SEPS do panel.rewardLabels[i]:Hide() end

    -- Map threshold positions to their data for quick lookup
    local threshMap = {}
    for i, t in ipairs(thresholds) do
        threshMap[t.at] = { idx = i, ilvl = t.ilvl, color = t.color }
    end

    local threshIdx = 1
    local sepUsed   = 0
    local rowUsed   = 0
    local yOff      = -PANEL_PAD

    for idx = 1, #entries do
        while threshIdx <= #thresholds and thresholds[threshIdx].at < idx do
            sepUsed = sepUsed + 1
            if sepUsed <= MAX_SEPS then
                local sep = panel.seps[sepUsed]
                sep:ClearAllPoints()
                sep:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yOff - SEP_HEIGHT / 2)
                sep:Show()
                yOff = yOff - SEP_HEIGHT
            end
            threshIdx = threshIdx + 1
        end

        rowUsed = rowUsed + 1
        if rowUsed <= MAX_ROWS then
            local row = panel.rows[rowUsed]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yOff)
            row:SetText(entries[idx].text)
            row:Show()

            -- If this entry is the last before a threshold, show reward ilvl
            local tm = threshMap[idx]
            if tm and tm.ilvl and tm.idx <= MAX_SEPS then
                local rl = panel.rewardLabels[tm.idx]
                rl:ClearAllPoints()
                rl:SetPoint("RIGHT", panel, "TOPRIGHT", -PANEL_PAD, yOff - LINE_HEIGHT / 2)
                local clr = tm.color or CLR.WHITE
                rl:SetText(clr .. tm.ilvl .. "|r")
                rl:Show()
            end

            yOff = yOff - LINE_HEIGHT
        end
    end

    while threshIdx <= #thresholds do
        sepUsed = sepUsed + 1
        if sepUsed <= MAX_SEPS then
            local sep = panel.seps[sepUsed]
            sep:ClearAllPoints()
            sep:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yOff - SEP_HEIGHT / 2)
            sep:Show()
            yOff = yOff - SEP_HEIGHT
        end
        threshIdx = threshIdx + 1
    end

    panel:SetHeight(math.max(math.abs(yOff) + PANEL_PAD, 30))

    -- Hide overflow by default
    if panel.overflowBtn then panel.overflowBtn:Hide() end
end

-------------------------------------------------------------------------------
-- Set overflow indicator on a panel
-- overflow: list of { text = "..." } entries to show in tooltip
-------------------------------------------------------------------------------
local function SetPanelOverflow(panel, overflow)
    if not panel or not panel.overflowBtn then return end
    if not overflow or #overflow == 0 then
        panel.overflowBtn:Hide()
        return
    end

    panel.overflowBtn.label:SetText(CLR.SLOT_LABEL .. "+" .. #overflow .. "|r")

    -- Strip color codes for tooltip readability
    local lines = {}
    for _, e in ipairs(overflow) do
        -- Keep the raw colored text — GameTooltip:AddLine handles it
        lines[#lines + 1] = e.text
    end
    panel.overflowBtn.tooltipLines = lines
    panel.overflowBtn:Show()
end

-------------------------------------------------------------------------------
-- Sort activities by threshold ascending
-------------------------------------------------------------------------------
local function SortByThreshold(activities)
    local sorted = {}
    for i, a in ipairs(activities) do sorted[i] = a end
    table.sort(sorted, function(a, b)
        if a.threshold ~= b.threshold then return a.threshold < b.threshold end
        return a.index < b.index
    end)
    return sorted
end

-------------------------------------------------------------------------------
-- Get reward ilvl for an activity slot
-- If the item isn't cached yet, request it and schedule a delayed refresh.
-------------------------------------------------------------------------------
local pendingItemRetry = false

local function GetRewardIlvl(activityID)
    if not C_WeeklyRewards or not C_WeeklyRewards.GetExampleRewardItemHyperlinks then
        return nil
    end
    local link = C_WeeklyRewards.GetExampleRewardItemHyperlinks(activityID)
    if not link then return nil end

    local ilvl
    if C_Item and C_Item.GetItemInfo then
        local _, _, _, il = C_Item.GetItemInfo(link)
        ilvl = il
    elseif GetItemInfo then
        local _, _, _, il = GetItemInfo(link)
        ilvl = il
    end

    if not ilvl then
        -- Item not cached — request load and schedule one retry
        local itemID = tonumber(link:match("item:(%d+)"))
        if itemID and C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
        if not pendingItemRetry then
            pendingItemRetry = true
            C_Timer.After(0.5, function()
                pendingItemRetry = false
                if VP.RefreshOverlay then VP:RefreshOverlay() end
            end)
        end
    end

    return ilvl
end

-------------------------------------------------------------------------------
-- DUNGEON layout
-- Uses GetSortedProgressForActivity(1, activityID) for level breakdown,
-- merges with local tracking + GetRunHistory for names.
-- Unmatched entries show "Dungeon +X" or "Dungeon H".
-------------------------------------------------------------------------------
local function BuildDungeonLayout()
    if not C_WeeklyRewards or not C_WeeklyRewards.GetActivities then
        return {{ text = CLR.UNCOMPLETE .. "No data|r" }}, {}
    end

    local activities = C_WeeklyRewards.GetActivities(TYPE_MYTHICPLUS)
    if not activities or #activities == 0 then
        return {{ text = CLR.UNCOMPLETE .. "No dungeon data|r" }}, {}
    end
    activities = SortByThreshold(activities)

    -- Get API level breakdown (like delves)
    local apiRuns = {}
    local lastAct = activities[#activities]
    if lastAct and C_WeeklyRewards.GetSortedProgressForActivity then
        local ok, tiers = pcall(C_WeeklyRewards.GetSortedProgressForActivity, 1, lastAct.id)
        if ok and tiers then
            for _, tp in ipairs(tiers) do
                local lvl = tp.difficulty or 0
                local count = tp.numPoints or 0
                for j = 1, count do
                    apiRuns[#apiRuns + 1] = { level = lvl }
                end
            end
        end
    end

    -- If API breakdown unavailable, fall back to GetRunHistory
    if #apiRuns == 0 then
        if C_MythicPlus and C_MythicPlus.RequestMapInfo then
            C_MythicPlus.RequestMapInfo()
        end
        if C_MythicPlus and C_MythicPlus.GetRunHistory then
            local rawRuns = C_MythicPlus.GetRunHistory(false, false) or {}
            for _, run in ipairs(rawRuns) do
                apiRuns[#apiRuns + 1] = { level = run.level or 0 }
            end
        end
    end

    -- Sort API runs by level descending
    table.sort(apiRuns, function(a, b) return a.level > b.level end)

    -- Gather named runs: local tracking + GetRunHistory
    local namedRuns = {}

    -- Local tracking (from CHALLENGE_MODE_COMPLETED / LFG_COMPLETION_REWARD)
    local localDungeons = VP.chardb and VP.chardb.dungeons or {}
    for _, d in ipairs(localDungeons) do
        namedRuns[#namedRuns + 1] = { name = d.name, level = d.level or 0 }
    end

    -- Also pull from GetRunHistory for M+ names (these are never heroic)
    if C_MythicPlus and C_MythicPlus.RequestMapInfo then
        C_MythicPlus.RequestMapInfo()
    end
    if C_MythicPlus and C_MythicPlus.GetRunHistory then
        local rawRuns = C_MythicPlus.GetRunHistory(false, false) or {}
        for _, run in ipairs(rawRuns) do
            local name = nil
            if run.mapChallengeModeID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
                local n = C_ChallengeMode.GetMapUIInfo(run.mapChallengeModeID)
                if n and n ~= "" then name = n end
            end
            if name then
                namedRuns[#namedRuns + 1] = { name = name, level = run.level or 0 }
            end
        end
    end

    -- Sort named runs by level descending
    table.sort(namedRuns, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return a.name < b.name
    end)

    -- Merge: match named runs to API runs by level
    local apiClaimed = {}
    local namedUsed  = {}

    -- First pass: exact level match
    for ni, nr in ipairs(namedRuns) do
        for ai, ar in ipairs(apiRuns) do
            if not apiClaimed[ai] and not namedUsed[ni] and ar.level == nr.level then
                apiClaimed[ai] = ni
                namedUsed[ni] = true
                break
            end
        end
    end

    -- Second pass: unmatched named runs claim any unclaimed API slot
    for ni, nr in ipairs(namedRuns) do
        if not namedUsed[ni] then
            for ai in ipairs(apiRuns) do
                if not apiClaimed[ai] then
                    apiClaimed[ai] = ni
                    namedUsed[ni] = true
                    break
                end
            end
        end
    end

    -- Build merged list
    local merged = {}
    for ai, ar in ipairs(apiRuns) do
        if apiClaimed[ai] then
            local nr = namedRuns[apiClaimed[ai]]
            merged[#merged + 1] = { name = nr.name, level = ar.level }
        else
            merged[#merged + 1] = { name = nil, level = ar.level }
        end
    end

    -- Build entries
    local maxThreshold = activities[#activities].threshold

    -- Determine M0 and HC cutoffs from slot ilvls
    -- Runs sorted descending. Thresholds mark vault slot boundaries.
    -- If a slot ilvl >= 256: all runs up to that threshold are M0
    -- If a slot ilvl < 256 (and > 0): that threshold and below are HC
    local ILVL_M0 = 256
    local m0Cutoff = 0          -- positions 1..m0Cutoff = confirmed M0
    local hcCutoff = maxThreshold + 1  -- positions hcCutoff..max = confirmed HC
    for _, a in ipairs(activities) do
        local ilvl = GetRewardIlvl(a.id)
        if ilvl then
            if ilvl >= ILVL_M0 then
                if a.threshold > m0Cutoff then m0Cutoff = a.threshold end
            else
                if a.threshold < hcCutoff then hcCutoff = a.threshold end
            end
        end
    end

    -- Lookup for dungeon difficulty (Heroic=2, M0=23) from ENCOUNTER_END
    local dDiffs = VP.chardb and VP.chardb.dungeonDiffs or {}

    local entries = {}
    local mergedIdx = 1
    for i = 1, maxThreshold do
        if mergedIdx <= #merged then
            local m = merged[mergedIdx]
            local kc = KeyColor(m.level)
            local kf = FormatKeyLevel(m.level)

            -- For level-0 entries, determine H vs M0
            local state = nil  -- "m0", "hc", "ambiguous", or nil (keystones use kc/kf)
            if m.level <= 0 then
                if m.name and dDiffs[m.name] then
                    -- ENCOUNTER_END told us the exact difficulty
                    if dDiffs[m.name] == 23 then
                        state = "m0"
                    else
                        state = "hc"
                    end
                elseif mergedIdx <= m0Cutoff then
                    state = "m0"
                elseif mergedIdx >= hcCutoff then
                    state = "hc"
                else
                    state = "ambiguous"
                end
            end

            -- Apply state to colors
            if state == "m0" then
                kc = CLR.VETERAN; kf = "M0"
            elseif state == "hc" then
                kc = CLR.EXPLORER; kf = "HC"
            end

            local text
            if state == "ambiguous" then
                local tag = CLR.EXPLORER .. "HC|r" .. CLR.WHITE .. " / " .. "|r" .. CLR.VETERAN .. "M0|r"
                if m.name then
                    if VP.db and VP.db.colorFullLine then
                        text = CLR.VETERAN .. TruncName(m.name) .. " HC / M0|r"
                    else
                        text = CLR.WHITE .. TruncName(m.name) .. "|r " .. tag
                    end
                else
                    if VP.db and VP.db.colorFullLine then
                        text = CLR.VETERAN .. "Dungeon HC / M0|r"
                    else
                        text = CLR.WHITE .. "Dungeon" .. "|r " .. tag
                    end
                end
            elseif m.name then
                if VP.db and VP.db.colorFullLine then
                    text = kc .. TruncName(m.name) .. " " .. kf .. "|r"
                else
                    text = CLR.WHITE .. TruncName(m.name) .. "|r " .. kc .. kf .. "|r"
                end
            else
                if VP.db and VP.db.colorFullLine then
                    text = kc .. "Dungeon " .. kf .. "|r"
                else
                    text = CLR.WHITE .. "Dungeon" .. "|r " .. kc .. kf .. "|r"
                end
            end
            entries[#entries + 1] = { text = text }
            mergedIdx = mergedIdx + 1
        else
            entries[#entries + 1] = { text = CLR.UNCOMPLETE .. "-|r" }
        end
    end

    -- Thresholds with ilvl — color based on per-slot activityTierID
    -- 102 = M0 (green), 101 = Heroic (white), 103+ = keystone
    local thresholds = {}
    for slot, a in ipairs(activities) do
        local ilvl = GetRewardIlvl(a.id)
        local color
        if a.level > 0 then
            color = KeyColor(a.level)
        elseif a.activityTierID == 102 then
            color = CLR.VETERAN   -- M0 = green
        elseif a.activityTierID == 101 then
            color = CLR.EXPLORER  -- Heroic = white
        else
            color = CLR.EXPLORER
        end
        thresholds[#thresholds + 1] = { at = a.threshold, ilvl = ilvl, color = color }
    end

    return entries, thresholds
end

-------------------------------------------------------------------------------
-- RAID layout
-------------------------------------------------------------------------------
local DIFF_NAMES = {
    [17] = "LFR", [14] = "Normal", [15] = "Heroic", [16] = "Mythic",
    [1] = "LFR", [2] = "Normal", [3] = "Heroic", [4] = "Mythic",
}

local function GetDiffName(level)
    if DIFF_NAMES[level] then return DIFF_NAMES[level] end
    if GetDifficultyInfo then
        local name = GetDifficultyInfo(level)
        if name and name ~= "" then return name end
    end
    return "Diff" .. tostring(level)
end

local function BuildRaidLayout()
    if not C_WeeklyRewards or not C_WeeklyRewards.GetActivities then
        return {{ text = CLR.UNCOMPLETE .. "No data|r" }}, {}, nil
    end

    local activities = C_WeeklyRewards.GetActivities(TYPE_RAID)
    if not activities or #activities == 0 then
        return {{ text = CLR.UNCOMPLETE .. "No raid data|r" }}, {}, nil
    end
    activities = SortByThreshold(activities)

    local kills = {}
    if GetNumSavedInstances then
        for i = 1, GetNumSavedInstances() do
            local _, _, _, difficultyID, locked, _, _, isRaid = GetSavedInstanceInfo(i)
            if isRaid and locked and GetSavedInstanceEncounterInfo then
                local diffName = GetDiffName(difficultyID)
                local enc = 1
                while true do
                    local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, enc)
                    if not bossName then break end
                    if isKilled then
                        kills[#kills + 1] = {
                            boss = bossName, difficulty = diffName, diffID = difficultyID,
                            encOrder = enc,
                        }
                    end
                    enc = enc + 1
                end
            end
        end
    end

    -- Sort: highest difficulty first, then journal order
    local diffRank = { Mythic = 4, Heroic = 3, Normal = 2, LFR = 1 }
    table.sort(kills, function(a, b)
        local oa, ob = diffRank[a.difficulty] or 0, diffRank[b.difficulty] or 0
        if oa ~= ob then return oa > ob end
        return a.encOrder < b.encOrder
    end)

    -- Deduplicate: keep only the highest difficulty per boss
    local seen = {}
    local uniqueKills = {}
    for _, k in ipairs(kills) do
        if not seen[k.boss] then
            seen[k.boss] = true
            uniqueKills[#uniqueKills + 1] = k
        end
    end
    kills = uniqueKills

    local maxThreshold = math.max(activities[#activities].threshold, 8)
    local entries = {}
    for i = 1, maxThreshold do
        if i <= #kills then
            local k = kills[i]
            local dc = DiffColor(k.difficulty)
            local ds = DiffShort(k.difficulty)
            if VP.db and VP.db.colorFullLine then
                entries[#entries + 1] = {
                    text = dc .. TruncName(k.boss) .. " " .. ds .. "|r"
                }
            else
                entries[#entries + 1] = {
                    text = CLR.WHITE .. TruncName(k.boss) .. "|r " .. dc .. ds .. "|r"
                }
            end
        else
            entries[#entries + 1] = { text = CLR.UNCOMPLETE .. "-|r" }
        end
    end

    local thresholds = {}
    for slot, a in ipairs(activities) do
        local ilvl = GetRewardIlvl(a.id)
        local diffName = GetDiffName(a.level)
        local color = DiffColor(diffName)
        thresholds[#thresholds + 1] = { at = a.threshold, ilvl = ilvl, color = color }
    end

    return entries, thresholds, nil
end

-------------------------------------------------------------------------------
-- WORLD + DELVES layout
-- Type 6 = World/Delves in Midnight.
-- C_WeeklyRewards.GetSortedProgressForActivity(6, activityID) returns exact
-- per-tier breakdown: { difficulty=8, numPoints=4 }, { difficulty=7, numPoints=1 }
-- We expand that into individual entries and merge with local tracking for names.
-------------------------------------------------------------------------------
local function BuildWorldLayout()
    local localDelves = VP.chardb and VP.chardb.delves or {}

    -- Read vault API (Type 6)
    local activities = nil
    if C_WeeklyRewards and C_WeeklyRewards.GetActivities then
        local raw = C_WeeklyRewards.GetActivities(TYPE_WORLD)
        if raw and #raw > 0 then
            activities = SortByThreshold(raw)
        end
    end

    local totalProgress = 0
    local maxThreshold  = 8
    local thresholds    = {}

    if activities then
        for _, a in ipairs(activities) do
            if a.progress > totalProgress then totalProgress = a.progress end
        end
        maxThreshold = math.max(activities[#activities].threshold, 8)
        for _, a in ipairs(activities) do
            local ilvl = GetRewardIlvl(a.id)
            local color = DelveIlvlColor(a.level)
            thresholds[#thresholds + 1] = { at = a.threshold, ilvl = ilvl, color = color }
        end
    else
        totalProgress = #localDelves
        thresholds = { { at = 2 }, { at = 4 }, { at = 8 } }
    end

    -- Get exact tier breakdown from the highest-threshold activity
    -- This covers ALL completed runs across all slots
    local apiRuns = {}  -- { { tier = N }, ... } one per completed run, sorted highest tier first
    if activities and C_WeeklyRewards.GetSortedProgressForActivity then
        local lastAct = activities[#activities]
        local ok, tierList = pcall(C_WeeklyRewards.GetSortedProgressForActivity, 6, lastAct.id)
        if ok and tierList then
            for _, tp in ipairs(tierList) do
                local tier = tp.difficulty or 0
                local count = tp.numPoints or 0
                for j = 1, count do
                    apiRuns[#apiRuns + 1] = { tier = tier }
                end
            end
        end
    end

    -- Sort API runs by tier descending
    table.sort(apiRuns, function(a, b) return a.tier > b.tier end)

    -- Sort local delve names by time descending (most recent first)
    local sortedLocal = {}
    for i, d in ipairs(localDelves) do sortedLocal[i] = d end
    table.sort(sortedLocal, function(a, b) return (a.time or 0) > (b.time or 0) end)

    -- Assign local names to API runs positionally
    -- Most recent local names fill from the top
    local merged = {}
    local localIdx = 1
    for _, ar in ipairs(apiRuns) do
        local name = nil
        if localIdx <= #sortedLocal then
            name = sortedLocal[localIdx].name
            localIdx = localIdx + 1
        end
        local t = ar.tier
        if t and t >= 1 then
            merged[#merged + 1] = { name = name, tier = t }
        else
            merged[#merged + 1] = { name = name or "World Activity", tier = 0 }
        end
    end

    -- Build entries
    local entries = {}
    local mergedIdx = 1
    for i = 1, maxThreshold do
        if mergedIdx <= #merged then
            local m = merged[mergedIdx]
            if m.tier > 0 then
                local tc = DelveTierColor(m.tier)
                local text
                if m.name then
                    if VP.db and VP.db.colorFullLine then
                        text = tc .. TruncName(m.name) .. " T" .. m.tier .. "|r"
                    else
                        text = CLR.WHITE .. TruncName(m.name) .. "|r " .. tc .. "T" .. m.tier .. "|r"
                    end
                else
                    -- No local name
                    local PREY_SUFFIX = { [1] = "N", [5] = "H", [8] = "NM" }
                    local prey = PREY_SUFFIX[m.tier]
                    if prey then
                        -- Delve Tx / Prey D — tier and prey rank colored
                        if VP.db and VP.db.colorFullLine then
                            text = tc .. "Delve T" .. m.tier .. " / Prey " .. prey .. "|r"
                        else
                            text = CLR.WHITE .. "Delve " .. "|r" .. tc .. "T" .. m.tier .. "|r" .. CLR.WHITE .. " / Prey " .. "|r" .. tc .. prey .. "|r"
                        end
                    else
                        -- Plain Delve Tx
                        if VP.db and VP.db.colorFullLine then
                            text = tc .. "Delve T" .. m.tier .. "|r"
                        else
                            text = CLR.WHITE .. "Delve" .. "|r " .. tc .. "T" .. m.tier .. "|r"
                        end
                    end
                end
                entries[#entries + 1] = { text = text }
            else
                entries[#entries + 1] = {
                    text = CLR.WORLD_DONE .. TruncName(m.name) .. "|r"
                }
            end
            mergedIdx = mergedIdx + 1
        else
            entries[#entries + 1] = { text = CLR.UNCOMPLETE .. "-|r" }
        end
    end

    return entries, thresholds
end

-------------------------------------------------------------------------------
-- Find anchor frame for a vault row
-------------------------------------------------------------------------------
local function FindRowAnchor(thresholdType)
    local vf = WeeklyRewardsFrame
    if not vf then return nil end

    if vf.Activities then
        for _, actFrame in ipairs(vf.Activities) do
            if actFrame.type == thresholdType then
                return actFrame
            end
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- Panel management
-------------------------------------------------------------------------------
local panels = {}

local function EnsurePanels()
    local vf = WeeklyRewardsFrame
    if not vf then return false end

    for _, pType in ipairs({ TYPE_MYTHICPLUS, TYPE_RAID, TYPE_WORLD }) do
        local name = "VPOverlayPanel_" .. pType
        if not panels[pType] then
            if _G[name] then
                panels[pType] = _G[name]
            else
                panels[pType] = CreatePanel(name, vf)
                _G[name] = panels[pType]
            end
        end
    end
    return true
end

-- Order to display: Dungeons, Raids, World (top to bottom)
local PANEL_ORDER = { TYPE_RAID, TYPE_MYTHICPLUS, TYPE_WORLD }

local function PositionPanels()
    local vf = WeeklyRewardsFrame
    if not vf then return end

    -- Find ANY activity frame to use as a vertical/horizontal reference
    local refFrame = nil
    if vf.Activities then
        for _, actFrame in ipairs(vf.Activities) do
            if actFrame:IsShown() then
                if not refFrame then
                    refFrame = actFrame
                else
                    -- Pick the topmost one
                    local aTop = actFrame:GetTop() or 0
                    local rTop = refFrame:GetTop() or 0
                    if aTop > rTop then refFrame = actFrame end
                end
            end
        end
    end

    -- Stack all panels vertically, anchored to the left of the reference
    -- or to the left of the vault frame itself
    local anchor = refFrame or vf
    local anchorPoint = refFrame and "TOPLEFT" or "TOPLEFT"
    local xOff = refFrame and -PANEL_WIDTH - 8 or -PANEL_WIDTH - 8
    local yOff = refFrame and 4 or -42

    for i, pType in ipairs(PANEL_ORDER) do
        local panel = panels[pType]
        if panel then
            panel:ClearAllPoints()
            if i == 1 then
                panel:SetPoint("TOPRIGHT", anchor, anchorPoint, -4, yOff)
            else
                local prevPanel = panels[PANEL_ORDER[i - 1]]
                if prevPanel then
                    panel:SetPoint("TOPRIGHT", prevPanel, "BOTTOMRIGHT", 0, -25)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Delve info + controls panel (to the left of the World panel)
-------------------------------------------------------------------------------
local infoPanel = nil
local dungeonInfoPanel = nil
-------------------------------------------------------------------------------
-- Helper: create a small info button (! with tooltip)
-------------------------------------------------------------------------------
local function CreateInfoBtn(parent, tooltipFunc)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 20)

    local txt = btn:CreateFontString(nil, "OVERLAY")
    txt:SetFont(FONT_FILE, 14, "")
    txt:SetPoint("CENTER")
    txt:SetText("|cFFFFCC00!|r")

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        tooltipFunc(GameTooltip)
        GameTooltip:Show()
        txt:SetText("|cFFFFFFFF!|r")
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
        txt:SetText("|cFFFFCC00!|r")
    end)

    return btn
end

local function DelveInfoTooltip(tooltip)
    tooltip:AddLine("Delve/Prey Tracking", 1, 0.82, 0)
    tooltip:AddLine(" ")
    tooltip:AddLine("Delve and prey levels are read from the Great Vault API automatically.", 1, 1, 1, true)
    tooltip:AddLine(" ")
    tooltip:AddLine("Delve names are tracked locally on completion. Names do not transfer between computers.", 1, 0.6, 0.4, true)
    tooltip:AddLine(" ")
    tooltip:AddLine("Prey cannot be auto-detected (open world). Prey tiers share the same API tier:", 0.7, 0.7, 0.7, true)
    tooltip:AddLine("  Normal Prey = T1", 0.7, 0.7, 0.7)
    tooltip:AddLine("  Hard Prey = T5", 0.7, 0.7, 0.7)
    tooltip:AddLine("  Nightmare Prey = T8", 0.7, 0.7, 0.7)
end

local function DungeonInfoTooltip(tooltip)
    tooltip:AddLine("Dungeon Tracking", 1, 0.82, 0)
    tooltip:AddLine(" ")
    tooltip:AddLine("Dungeon levels are read from the Great Vault API. Keystone levels are accurate.", 1, 1, 1, true)
    tooltip:AddLine(" ")
    tooltip:AddLine("The API reports Heroic and M0 at the same difficulty level. The addon uses the vault reward ilvl to distinguish them: 256+ = M0, 243 = Heroic. Boss kill events provide exact data when you complete a dungeon.", 1, 0.6, 0.4, true)
end

-------------------------------------------------------------------------------
-- Delve info panel (just ! with tooltip)
-------------------------------------------------------------------------------
local function EnsureInfoPanel()
    if infoPanel then return infoPanel end
    local vf = WeeklyRewardsFrame
    if not vf then return nil end

    local f = CreateFrame("Frame", "VPDelveInfoPanel", vf, "BackdropTemplate")
    f:SetSize(28, 28)
    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.03, 0.03, 0.08, PANEL_ALPHA)
    f:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.6)
    f:SetFrameLevel(vf:GetFrameLevel() + 16)

    local warnBtn = CreateInfoBtn(f, DelveInfoTooltip)
    warnBtn:SetPoint("CENTER", f, "CENTER", 0, 0)

    infoPanel = f
    return f
end

-------------------------------------------------------------------------------
-- Dungeon info panel (just ! with tooltip)
-------------------------------------------------------------------------------
local function EnsureDungeonInfoPanel()
    if dungeonInfoPanel then return dungeonInfoPanel end
    local vf = WeeklyRewardsFrame
    if not vf then return nil end

    local f = CreateFrame("Frame", "VPDungeonInfoPanel", vf, "BackdropTemplate")
    f:SetSize(28, 28)
    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.03, 0.03, 0.08, PANEL_ALPHA)
    f:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.6)
    f:SetFrameLevel(vf:GetFrameLevel() + 16)

    local warnBtn = CreateInfoBtn(f, DungeonInfoTooltip)
    warnBtn:SetPoint("CENTER", f, "CENTER", 0, 0)

    dungeonInfoPanel = f
    return f
end

-------------------------------------------------------------------------------
-- Settings panel (top-right of vault frame)
-- Two toggle buttons: minimap button and hover summary
-------------------------------------------------------------------------------
local settingsPanel = nil

local function MakeToggleBtn(parent, label, getState, toggle)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(120, 16)

    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT_FILE, 9, "")
    fs:SetPoint("LEFT", f, "LEFT", 0, 0)
    f.label = fs

    local function UpdateLabel()
        local on = getState()
        local state = on and "|cFF00FF00ON|r" or "|cFFFF6666OFF|r"
        fs:SetText(label .. ": " .. state)
    end

    f:SetScript("OnClick", function()
        toggle()
        UpdateLabel()
    end)
    f:SetScript("OnEnter", function(self)
        fs:SetTextColor(1, 1, 1)
    end)
    f:SetScript("OnLeave", function()
        UpdateLabel()
    end)

    f.UpdateLabel = UpdateLabel
    UpdateLabel()
    return f
end

local function EnsureSettingsPanel()
    if settingsPanel then return settingsPanel end
    local vf = WeeklyRewardsFrame
    if not vf then return nil end

    local f = CreateFrame("Frame", "VPSettingsPanel", vf, "BackdropTemplate")
    f:SetSize(130, 66)
    f:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.03, 0.03, 0.08, PANEL_ALPHA)
    f:SetBackdropBorderColor(0.4, 0.35, 0.2, 0.6)
    f:SetFrameLevel(vf:GetFrameLevel() + 16)

    local minimapToggle = MakeToggleBtn(f, "Minimap Button",
        function() return VP.db and VP.db.minimapBtn end,
        function()
            if VP.db then
                VP.db.minimapBtn = not VP.db.minimapBtn
                VP:UpdateMinimapButton()
            end
        end
    )
    minimapToggle:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)

    local hoverToggle = MakeToggleBtn(f, "Hover Summary",
        function() return VP.db and VP.db.hoverSummary end,
        function()
            if VP.db then
                VP.db.hoverSummary = not VP.db.hoverSummary
            end
        end
    )
    hoverToggle:SetPoint("TOPLEFT", minimapToggle, "BOTTOMLEFT", 0, -4)

    local colorToggle = MakeToggleBtn(f, "Color Full Line",
        function() return VP.db and VP.db.colorFullLine end,
        function()
            if VP.db then
                VP.db.colorFullLine = not VP.db.colorFullLine
                if VP.RefreshOverlay then VP:RefreshOverlay() end
            end
        end
    )
    colorToggle:SetPoint("TOPLEFT", hoverToggle, "BOTTOMLEFT", 0, -4)

    f.minimapToggle = minimapToggle
    f.hoverToggle = hoverToggle
    f.colorToggle = colorToggle

    settingsPanel = f
    return f
end

-------------------------------------------------------------------------------
-- Refresh / Hide
-------------------------------------------------------------------------------
local function RefreshOverlay()
    if not WeeklyRewardsFrame or not WeeklyRewardsFrame:IsShown() then return end
    if not EnsurePanels() then return end

    local dE, dT = BuildDungeonLayout()
    PopulatePanel(panels[TYPE_MYTHICPLUS], dE, dT)

    local rE, rT, rOverflow = BuildRaidLayout()
    PopulatePanel(panels[TYPE_RAID], rE, rT)
    SetPanelOverflow(panels[TYPE_RAID], rOverflow)

    local wE, wT = BuildWorldLayout()
    PopulatePanel(panels[TYPE_WORLD], wE, wT)

    PositionPanels()
    for _, p in pairs(panels) do p:Show() end

    -- Position delve info panel to the left of the World/Delves panel
    local ip = EnsureInfoPanel()
    if ip and panels[TYPE_WORLD] then
        ip:ClearAllPoints()
        ip:SetPoint("TOPRIGHT", panels[TYPE_WORLD], "TOPLEFT", -4, 0)
        ip:Show()
    end

    -- Position dungeon info panel bottom-aligned with the Dungeon panel
    local dip = EnsureDungeonInfoPanel()
    if dip and panels[TYPE_MYTHICPLUS] then
        dip:ClearAllPoints()
        dip:SetPoint("BOTTOMRIGHT", panels[TYPE_MYTHICPLUS], "BOTTOMLEFT", -4, 0)
        dip:Show()
    end

    -- Settings panel — bottom-aligned with the World/Delves panel
    local sp = EnsureSettingsPanel()
    if sp and panels[TYPE_WORLD] then
        sp:ClearAllPoints()
        -- Always anchor bottom to the delves panel bottom, offset left past info panel
        local xOff = -4
        if ip then xOff = -(ip:GetWidth() + 8) end
        sp:SetPoint("BOTTOMRIGHT", panels[TYPE_WORLD], "BOTTOMLEFT", xOff, 0)
        if sp.minimapToggle then sp.minimapToggle.UpdateLabel() end
        if sp.hoverToggle then sp.hoverToggle.UpdateLabel() end
        if sp.colorToggle then sp.colorToggle.UpdateLabel() end
        sp:Show()
    end
end

local function HideOverlay()
    for _, p in pairs(panels) do if p then p:Hide() end end
    if infoPanel then infoPanel:Hide() end
    if dungeonInfoPanel then dungeonInfoPanel:Hide() end
    if settingsPanel then settingsPanel:Hide() end
end

-------------------------------------------------------------------------------
-- Hook vault frame
-------------------------------------------------------------------------------
local function HookVaultFrame()
    if overlayReady then return end
    if not WeeklyRewardsFrame then return end

    EnsurePanels()

    WeeklyRewardsFrame:HookScript("OnShow", function()
        C_Timer.After(0.1, RefreshOverlay)
    end)

    WeeklyRewardsFrame:HookScript("OnHide", function()
        HideOverlay()
    end)

    overlayReady = true

    if WeeklyRewardsFrame:IsShown() then
        C_Timer.After(0.2, RefreshOverlay)
    end
end

-------------------------------------------------------------------------------
-- Loader
-------------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "Blizzard_WeeklyRewards" then
        C_Timer.After(0.1, HookVaultFrame)
    elseif event == "PLAYER_ENTERING_WORLD" then
        if WeeklyRewardsFrame then
            C_Timer.After(0.5, HookVaultFrame)
        end
    end
end)

if WeeklyRewardsFrame then
    C_Timer.After(0.1, HookVaultFrame)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function VP:RefreshOverlay()
    RefreshOverlay()
end
