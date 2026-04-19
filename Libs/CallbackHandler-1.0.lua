-- CallbackHandler-1.0 - minimal callback mixin
local MAJOR, MINOR = "CallbackHandler-1.0", 7
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)
if not CallbackHandler then return end

local meta = { __index = function(tbl, key) tbl[key] = {} return tbl[key] end }

function CallbackHandler.New(_self, target)
    local registry = setmetatable({}, meta)
    target = target or {}

    function target.RegisterCallback(self_or_target, eventname, method, ...)
        local self = self_or_target
        if type(eventname) ~= "string" then error("Usage: RegisterCallback(event, method)") end
        method = method or eventname
        local first = ...
        registry[eventname][self] = { method = method, arg = first }
    end

    function target.UnregisterCallback(self_or_target, eventname)
        if registry[eventname] then
            registry[eventname][self_or_target] = nil
        end
    end

    function target.UnregisterAllCallbacks(self_or_target)
        for event, tbl in pairs(registry) do
            tbl[self_or_target] = nil
        end
    end

    function target:Fire(eventname, ...)
        local events = rawget(registry, eventname)
        if not events then return end
        for self, info in pairs(events) do
            local method = info.method
            if type(method) == "string" then
                if self[method] then self[method](self, eventname, ...) end
            elseif type(method) == "function" then
                if info.arg ~= nil then
                    method(info.arg, eventname, ...)
                else
                    method(eventname, ...)
                end
            end
        end
    end

    return target
end
