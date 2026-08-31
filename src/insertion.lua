--
-- insertion
--
-- Author: Stijn Wopereis
-- Description: handles the insertions
-- Name: insertion
-- Hide: yes
--
-- Copyright (c) Wopster, 2022

---@type string directory of the mod.
local modDirectory = g_currentModDirectory or ""
---@type string name of the mod.
local modName = g_currentModName or "unknown"

local insertionFunctions = {
    "onPreLoad",
    "onLoadFinished"
}

local insertionRootFile = "resources/insertions.xml"

local insertions = {}

local typeToXMLSetFunction = {
    ["bool"] = 'setBool',
    ["int"] = 'setInt',
    ["float"] = 'setFloat',
    ["string"] = 'setString',
}

local typeToXMLGetFunction = {
    ["bool"] = 'getBool',
    ["int"] = 'getInt',
    ["float"] = 'getFloat',
    ["string"] = 'getString',
}

---@type table<string, boolean>
local mappablePaths = {
    ["attributes"] = { isIterable = false, childPath = "", isRelative = false },
    ["manureSystem"] = { isIterable = false, childPath = "", isRelative = true },
    ["manureSystemConnectors"] = { isIterable = true, childPath = "connector", isRelative = true },
    ["manureSystemFillArm"] = { isIterable = false, childPath = "", isRelative = true },
    ["manureSystemFillArmReceiver"] = { isIterable = false, childPath = "", isRelative = true },
    ["manureSystemPumpMotor"] = { isIterable = false, childPath = "", isRelative = true },
    ["manureSystemPumpMixer"] = { isIterable = false, childPath = "", isRelative = true },
}

local function replaceSanitized(input, what, with)
    what = string.gsub(what, "[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%1") -- escape pattern
    with = string.gsub(with, "[%%]", "%%%%") -- escape replacement
    return input:gsub(what, with)
end

local function generateSpecObject(data)
    local spec = {
        __d = data
    }

    spec.prerequisitesPresent = function()
        return true
    end

    spec.onPreLoad = function(self)
        if g_currentMission.manureSystem.debug then
            log("MS - loading XML mapping for", data.xml, self.typeName)
        end

        for baseKey, mapping in pairs(data.mapping) do
            for _, map in ipairs(mapping) do
                local key = map.isRelative and baseKey .. map.xmlKey or map.xmlKey

                if g_currentMission.manureSystem.debug then
                    log(("MS map - <%s> [%s] %s"):format(key, map.xmlType, map.xmlValue))
                end

                self.xmlFile[typeToXMLSetFunction[map.xmlType]](self.xmlFile, key, map.xmlValue)
            end
        end

        print(("[MS-INSERT-DIAG] onPreLoad FIRED: xml='%s' type='%s' hasProp(connector0)=%s hasProp(hasConnectors)=%s"):format(tostring(data.xml), tostring(self.typeName), tostring(self.xmlFile:hasProperty("vehicle.manureSystemConnectors.connector(0)")), tostring(self.xmlFile:hasProperty("vehicle.manureSystem#hasConnectors"))))

        if data.reloadStoreItem then
            local storeItem = g_storeManager:getItemByXMLFilename(self.configFileName)

            if storeItem.species == "vehicle" then
                local rootName = self.xmlFile:getRootName()

                storeItem.configurations, storeItem.defaultConfigurationIds = StoreItemUtil.getConfigurationsFromXML(self.xmlFile, rootName, storeItem.baseDir, storeItem.customEnvironment, storeItem.isMod, storeItem)
                storeItem.subConfigurations = StoreItemUtil.getSubConfigurationsFromXML(storeItem.configurations)
                storeItem.configurationSets = StoreItemUtil.getConfigurationSetsFromXML(storeItem, self.xmlFile, rootName, storeItem.baseDir, storeItem.customEnvironment, storeItem.isMod)
                storeItem.canBeSold = true
            end
        end
    end

    spec.onLoadFinished = function()
        if data.reloadStoreItem then
            g_messageCenter:publish(MessageType.STORE_ITEMS_RELOADED)
            data.reloadStoreItem = false
        end
    end

    return spec
end

local function injectRegistry(xmlFilename, orgEntry, typeName, data)
    local generatedSpec
    local doInject = orgEntry ~= nil

    -- FS25: the load data no longer reliably carries a typeName (it is nil during
    -- shop preview / placement mouse reloads), which crashed string.split once per
    -- mouse event and stopped the vehicle from loading. Only split when we actually
    -- have a string; otherwise keep whatever doInject already resolved to.
    if doInject and type(typeName) == "string" then
        local stringParts = string.split(typeName, ".")

        if #stringParts ~= 1 then
            local typeModName = unpack(stringParts)
            doInject = doInject and not (g_specializationManager:getSpecializationObjectByName(typeModName .. ".manureSystemRegistry") ~= nil)
        end
    end

    if doInject then
        generatedSpec = generateSpecObject(insertions[xmlFilename])

        for _, insertionFunction in ipairs(insertionFunctions) do
            table.addElement(orgEntry.eventListeners[insertionFunction], generatedSpec)
        end
    end

    return doInject, generatedSpec
end

-- FS25: the vehicle/placeable load path may not pass data.filename, so resolve the
-- config path tolerantly and bail out to superFunc when nothing usable is found
-- (avoids Utils.getModNameAndBaseDirectory(nil) crashing once per load).
local function getInsertionFilename(self, data)
    if data ~= nil then
        if data.filename ~= nil then
            return data.filename
        end
        if data.xmlFilename ~= nil then
            return data.xmlFilename
        end
        if data.configFileName ~= nil then
            return data.configFileName
        end
    end
    if self ~= nil then
        if self.configFileName ~= nil then
            return self.configFileName
        end
        if self.xmlFilename ~= nil then
            return self.xmlFilename
        end
    end
    return nil
end

-- FS25: resolve the vehicle/placeable type name tolerantly. The load data may not
-- carry typeName anymore, so fall back to the instance's own typeName.
local function getInsertionTypeName(self, data)
    if data ~= nil and data.typeName ~= nil then
        return data.typeName
    end
    if self ~= nil and self.typeName ~= nil then
        return self.typeName
    end
    return nil
end

-- FS25: the transient onPreLoad event-listener injection (below) never fires,
-- because FS25 resolves each vehicle instance's event listeners at construction
-- (new()) -- BEFORE Vehicle:load runs -- so a listener added to the type during
-- load is never seen. Instead, apply the insertion mapping directly to the
-- vehicle's own xmlFile from the manure specializations' onLoad (which we have
-- confirmed does run). Idempotent via the msInsertionApplied guard so it is safe
-- to call from every manure spec's onLoad regardless of order.
function ManureSystemApplyInsertion(self)
    if self == nil or self.xmlFile == nil then
        return
    end

    if self.msInsertionApplied then
        return
    end

    local filename = getInsertionFilename(self, nil)
    if filename == nil then
        return
    end

    local _, baseDir = Utils.getModNameAndBaseDirectory(filename)
    local xmlFilename = replaceSanitized(filename, baseDir, "")
    local data = insertions[xmlFilename]
    if data == nil then
        return
    end

    for baseKey, mapping in pairs(data.mapping) do
        for _, map in ipairs(mapping) do
            local key = map.isRelative and baseKey .. map.xmlKey or map.xmlKey
            self.xmlFile[typeToXMLSetFunction[map.xmlType]](self.xmlFile, key, map.xmlValue)
        end
    end

    self.msInsertionApplied = true

    print(("[MS-INSERT-DIAG] applyInsertion: cfg='%s' connector0=%s hasConnectors=%s"):format(tostring(filename), tostring(self.xmlFile:hasProperty("vehicle.manureSystemConnectors.connector(0)")), tostring(self.xmlFile:hasProperty("vehicle.manureSystem#hasConnectors"))))
end

local function vehicleLoad(self, superFunc, data, ...)
    local filename = getInsertionFilename(self, data)
    if filename == nil then
        return superFunc(self, data, ...)
    end

    local _, baseDir = Utils.getModNameAndBaseDirectory(filename)
    local xmlFilename = replaceSanitized(filename, baseDir, "")

    print(("[MS-INSERT-DIAG] vehicle load: file='%s' stripped='%s' matched=%s"):format(tostring(filename), tostring(xmlFilename), tostring(insertions[xmlFilename] ~= nil)))

    if insertions[xmlFilename] == nil then
        return superFunc(self, data, ...)
    end

    local typeName = getInsertionTypeName(self, data)
    local orgEntry = typeName ~= nil and g_vehicleTypeManager:getTypeByName(typeName) or nil
    local isInjected, registrySpec = injectRegistry(xmlFilename, orgEntry, typeName, data)

    print(("[MS-INSERT-DIAG] vehicle MATCH: stripped='%s' type='%s' orgEntry=%s injected=%s"):format(tostring(xmlFilename), tostring(typeName), tostring(orgEntry ~= nil), tostring(isInjected)))

    local loadingState = superFunc(self, data, ...)
    if isInjected then
        for _, insertionFunction in ipairs(insertionFunctions) do
            table.removeElement(orgEntry.eventListeners[insertionFunction], registrySpec)
        end
    end

    return loadingState
end

local function placeableLoad(self, superFunc, data, ...)
    local filename = getInsertionFilename(self, data)
    if filename == nil then
        return superFunc(self, data, ...)
    end

    local _, baseDir = Utils.getModNameAndBaseDirectory(filename)
    local xmlFilename = replaceSanitized(filename, baseDir, "")

    if insertions[xmlFilename] == nil then
        return superFunc(self, data, ...)
    end

    local typeName = getInsertionTypeName(self, data)
    local orgEntry = typeName ~= nil and g_placeableTypeManager:getTypeByName(typeName) or nil
    local isInjected, registrySpec = injectRegistry(xmlFilename, orgEntry, typeName, data)

    local loadingState = superFunc(self, data, ...)
    if isInjected then
        for _, insertionFunction in ipairs(insertionFunctions) do
            table.removeElement(orgEntry.eventListeners[insertionFunction], registrySpec)
        end
    end

    return loadingState
end

local function loadInsertion(filePath, type)
    local filename = Utils.getFilename(filePath, modDirectory)

    ---Replace the 'data.' prefix and remove the iteration marker for the xml root
    local function convertToMappingKey(baseKey)
        local key = baseKey:gsub("data.", "", 1)
        return key:gsub("%(%d*%)", "", 1)
    end

    local function loadMapping(xmlFile, baseKey, mapping, isRelative)
        local mappingKey = convertToMappingKey(baseKey)
        mapping[mappingKey] = {}

        xmlFile:iterate(baseKey .. ".entry", function(_, key)
            local map = {}
            map.isRelative = isRelative
            map.xmlType = xmlFile:getString(key .. "#type", "string")
            map.xmlKey = xmlFile:getString(key .. "#key")
            map.xmlValue = xmlFile[typeToXMLGetFunction[map.xmlType]](xmlFile, key .. "#value")

            table.insert(mapping[mappingKey], map)
        end)
    end

    local xmlFile = XMLFile.load(type, filename)

    xmlFile:iterate("data." .. type, function(_, xmlRootKey)
        local entry = {}
        entry.name = Utils.getFilenameInfo(filename)
        entry.xml = xmlFile:getString(xmlRootKey .. "#xml")
        entry.reloadStoreItem = xmlFile:getBool(xmlRootKey .. "#reloadStoreItem") or false

        entry.mapping = {}

        for path, info in pairs(mappablePaths) do
            if info.isIterable then
                xmlFile:iterate(xmlRootKey .. "." .. path .. "." .. info.childPath, function(_, key)
                    loadMapping(xmlFile, key, entry.mapping, info.isRelative)
                end)
            else
                loadMapping(xmlFile, xmlRootKey .. "." .. path, entry.mapping, info.isRelative)
            end
        end

        insertions[entry.xml] = entry
    end)

    xmlFile:delete()
end

local function loadInsertions()
    local xmlFile = XMLFile.load("insertions", modDirectory .. insertionRootFile)
    xmlFile:iterate("files.file", function(_, key)
        local type = xmlFile:getString(key .. "#type") or "vehicle"
        local path = xmlFile:getString(key .. "#path")
        loadInsertion(path, type)
    end)

    for insertionKey in pairs(insertions) do
        print(("[MS-INSERT-DIAG] registered insertion key: '%s'"):format(tostring(insertionKey)))
    end

    xmlFile:delete()
end

local function consoleCommandReloadVehicle(mission, superFunc, resetVehicle, radius)
    loadInsertions()
    return superFunc(mission, resetVehicle, radius)
end

local function init()
    loadInsertions()
    Vehicle.load = Utils.overwrittenFunction(Vehicle.load, vehicleLoad)
    Placeable.load = Utils.overwrittenFunction(Placeable.load, placeableLoad)
    FSBaseMission.consoleCommandReloadVehicle = Utils.overwrittenFunction(FSBaseMission.consoleCommandReloadVehicle, consoleCommandReloadVehicle)
end

init()
