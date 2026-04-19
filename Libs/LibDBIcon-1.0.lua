-- LibDBIcon-1.0 - minimal minimap button management
local MAJOR, MINOR = "LibDBIcon-1.0", 46
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.objects = lib.objects or {}
lib.callbackRegistered = lib.callbackRegistered or {}
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.notCreated = lib.notCreated or {}

local ldb = LibStub("LibDataBroker-1.1")

local BUTTON_SIZE = 31
local ICON_SIZE = 20
local DEFAULT_RADIUS = 80

local function GetPosition(angle, radius)
    return math.cos(angle) * radius, math.sin(angle) * radius
end

local function UpdatePosition(button, position)
    local angle = math.rad(position or 225)
    local x, y = GetPosition(angle, button.radius or DEFAULT_RADIUS)
    button:ClearAllPoints()
    button:SetPoint("CENTER", button.minimap or Minimap, "CENTER", x, y)
end

local function OnDragStart(self)
    self:LockHighlight()
    self.isMouseDown = true
    self:SetScript("OnUpdate", function(self)
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        local pos = math.deg(math.atan2(cy - my, cx - mx))
        if self.db then self.db.minimapPos = pos end
        UpdatePosition(self, pos)
    end)
end

local function OnDragStop(self)
    self:SetScript("OnUpdate", nil)
    self.isMouseDown = false
    self:UnlockHighlight()
end

local function OnEnter(self)
    if self.isMouseDown then return end
    local obj = self.dataObject
    if obj.OnTooltipShow then
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        obj.OnTooltipShow(GameTooltip)
        GameTooltip:Show()
    elseif obj.OnEnter then
        obj.OnEnter(self)
    end
end

local function OnLeave(self)
    local obj = self.dataObject
    if obj.OnLeave then
        obj.OnLeave(self)
    else
        GameTooltip:Hide()
    end
end

local function OnClick(self, button)
    local obj = self.dataObject
    if obj.OnClick then
        obj.OnClick(self, button)
    end
end

local function CreateButton(name, dataObject, db)
    local button = CreateFrame("Button", "LibDBIcon10_" .. name, Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameLevel(8)
    button:SetClampedToScreen(true)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton", "RightButton")
    button:RegisterForClicks("anyUp")
    button:SetHighlightTexture(136477)  -- UI-Minimap-ZoomButton-Highlight

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture(136430)  -- MiniMap-TrackingBorder
    overlay:SetPoint("TOPLEFT")
    button.overlay = overlay

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetTexture(136467)  -- UI-Minimap-Background
    background:SetPoint("CENTER", button, "CENTER", 0, 1)
    button.background = background

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("CENTER", button, "CENTER", 0, 1)
    icon:SetTexture(dataObject.icon)
    button.icon = icon

    button.dataObject = dataObject
    button.db = db
    button.radius = DEFAULT_RADIUS

    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", OnLeave)
    button:SetScript("OnClick", OnClick)
    button:SetScript("OnDragStart", OnDragStart)
    button:SetScript("OnDragStop", OnDragStop)

    UpdatePosition(button, db and db.minimapPos)

    if db and db.hide then
        button:Hide()
    else
        button:Show()
    end

    lib.objects[name] = button

    -- Watch for icon changes
    if not lib.callbackRegistered[name] then
        ldb.RegisterCallback(lib, "LibDataBroker_AttributeChanged_" .. name, function(event, dname, key, value, obj)
            if key == "icon" and button.icon then
                button.icon:SetTexture(value)
            end
        end)
        lib.callbackRegistered[name] = true
    end

    return button
end

function lib:Register(name, dataObject, db)
    if self.objects[name] or self.notCreated[name] then return end
    if not Minimap then
        self.notCreated[name] = { dataObject = dataObject, db = db }
        return
    end
    CreateButton(name, dataObject, db)
end

function lib:Show(name)
    local button = self.objects[name]
    if button then
        button.db.hide = false
        button:Show()
    end
end

function lib:Hide(name)
    local button = self.objects[name]
    if button then
        button.db.hide = true
        button:Hide()
    end
end

function lib:IsRegistered(name)
    return self.objects[name] ~= nil or self.notCreated[name] ~= nil
end

function lib:GetMinimapButton(name)
    return self.objects[name]
end

function lib:Refresh(name, db)
    local button = self.objects[name]
    if button then
        if db then button.db = db end
        UpdatePosition(button, button.db and button.db.minimapPos)
        if button.db and button.db.hide then
            button:Hide()
        else
            button:Show()
        end
    end
end
