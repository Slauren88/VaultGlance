-------------------------------------------------------------------------------
-- VaultGlance – Minimap.lua
-- Minimap button via LibDBIcon: click to open Great Vault, hover for summary.
-------------------------------------------------------------------------------
local _, VP = ...

local ADDON_NAME = "VaultGlance"
local VAULT_ICON = "Interface\\Icons\\Achievement_Dungeon_GloryOfTheRaider"

local function OpenVaultSettings()
    if VP.OpenSettings then
        VP:OpenSettings()
    end
end

function VaultGlance_OnAddonCompartmentClick()
    OpenVaultSettings()
end

function VaultGlance_OnAddonCompartmentEnter(button)
    if MenuUtil and MenuUtil.ShowTooltip then
        MenuUtil.ShowTooltip(button, function(tooltip)
            tooltip:SetText("VaultGlance\nOpen settings")
        end)
        return
    end

    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText("VaultGlance")
    GameTooltip:AddLine("Open settings", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function VaultGlance_OnAddonCompartmentLeave(button)
    if MenuUtil and MenuUtil.HideTooltip then
        MenuUtil.HideTooltip(button)
        return
    end
    GameTooltip:Hide()
end

-------------------------------------------------------------------------------
-- LibDataBroker data object
-------------------------------------------------------------------------------
local ldb = LibStub("LibDataBroker-1.1")
local dataObj = ldb:NewDataObject(ADDON_NAME, {
    type  = "launcher",
    label = ADDON_NAME,
    icon  = VAULT_ICON,

    OnClick = function(self, button)
        if button == "LeftButton" then
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
        end
    end,

    OnTooltipShow = function(tooltip)
        if not VP.db or not VP.db.hoverSummary then
            tooltip:AddLine("VaultGlance")
            tooltip:AddLine("Click to open Great Vault", 0.7, 0.7, 0.7)
            return
        end
        VP:PopulateSummaryTooltip(tooltip)
    end,
})

-------------------------------------------------------------------------------
-- Public API for Core.lua
-------------------------------------------------------------------------------
function VP:CreateMinimapButton()
    if not self.db then return end
    -- Ensure minimap sub-table exists for LibDBIcon
    if not self.db.minimap then
        self.db.minimap = { hide = not self.db.minimapBtn, minimapPos = self.db.minimapAngle or 225 }
    end
    local icon = LibStub("LibDBIcon-1.0")
    if not icon:IsRegistered(ADDON_NAME) then
        icon:Register(ADDON_NAME, dataObj, self.db.minimap)
    end
end

function VP:ShowMinimapButton()
    self:CreateMinimapButton()
    local icon = LibStub("LibDBIcon-1.0")
    if icon:IsRegistered(ADDON_NAME) then
        icon:Show(ADDON_NAME)
    end
end

function VP:HideMinimapButton()
    local icon = LibStub("LibDBIcon-1.0")
    if icon:IsRegistered(ADDON_NAME) then
        icon:Hide(ADDON_NAME)
    end
end

function VP:UpdateMinimapButton()
    if not self.db then return end
    -- Sync minimap sub-table with the toggle
    if self.db.minimap then
        self.db.minimap.hide = not self.db.minimapBtn
    end
    if self.db.minimapBtn then
        self:ShowMinimapButton()
    else
        self:HideMinimapButton()
    end
end

-------------------------------------------------------------------------------
-- Init on PLAYER_LOGIN (called from Core.lua event handler)
-------------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function()
    C_Timer.After(1, function()
        VP:UpdateMinimapButton()
    end)
end)
