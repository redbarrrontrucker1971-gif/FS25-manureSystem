--
-- HosePlayer
--
-- Author: Stijn Wopereis
-- Description: Injection class to handle all the hose interactions with the player.
-- Name: HosePlayer
-- Hide: yes
--
-- Copyright (c) Wopster, 2019 - 2023

---@class HosePlayer
HosePlayer = {}

local HosePlayer_mt = Class(HosePlayer)

function HosePlayer.new(isClient, isServer, mission, input)
    local self = setmetatable({}, HosePlayer_mt)

    self.isClient = isClient
    self.isServer = isServer
    self.mission = mission
    self.input = input

    -- FS25: the Player class and its player-state machine were rewritten, so these
    -- FS22-era injections are incompatible (PlayerStatePickup etc. are nil, which
    -- crashed HosePlayer during player load). Only install them when the legacy API
    -- is actually present; otherwise on-foot hose handling stays disabled for this
    -- build (to be re-implemented against the FS25 player API in a later build).
    local hasLegacyPlayerApi = Player ~= nil
        and PlayerStateThrow ~= nil and PlayerStatePickup ~= nil
        and PlayerStateWalk ~= nil and PlayerStateRun ~= nil
        and Player.pickUpObject ~= nil and Player.checkObjectInRange ~= nil

    if not hasLegacyPlayerApi then
        print("[ManureSystem] HosePlayer: FS25 player API detected; installing FS25 on-foot hose interaction (build v4).")
        HosePlayer.installFS25(self)
        return self
    end

    Player.readUpdateStream = Utils.appendedFunction(Player.readUpdateStream, HosePlayer.inj_player_readUpdateStream)
    Player.writeUpdateStream = Utils.appendedFunction(Player.writeUpdateStream, HosePlayer.inj_player_writeUpdateStream)
    Player.update = Utils.appendedFunction(Player.update, HosePlayer.inj_player_update)
    Player.onLeave = Utils.appendedFunction(Player.onLeave, HosePlayer.inj_player_onLeave)

    Player.updateActionEvents = Utils.appendedFunction(Player.updateActionEvents, HosePlayer.inj_player_updateActionEvents)
    Player.registerActionEvents = Utils.prependedFunction(Player.registerActionEvents, HosePlayer.inj_player_registerActionEvents)

    Player.pickUpObject = Utils.overwrittenFunction(Player.pickUpObject, HosePlayer.inj_player_pickUpObject)

    Player.checkObjectInRange = Utils.overwrittenFunction(Player.checkObjectInRange, HosePlayer.inj_player_checkObjectInRange)
    PlayerStateThrow.isAvailable = Utils.overwrittenFunction(PlayerStateThrow.isAvailable, HosePlayer.inj_playerStateThrow_isAvailable)
    PlayerStatePickup.isAvailable = Utils.overwrittenFunction(PlayerStatePickup.isAvailable, HosePlayer.inj_playerStatePickup_isAvailable)

    PlayerStateWalk.isAvailable = Utils.overwrittenFunction(PlayerStateWalk.isAvailable, HosePlayer.inj_playerStateWalk_isAvailable)
    PlayerStateRun.isAvailable = Utils.overwrittenFunction(PlayerStateRun.isAvailable, HosePlayer.inj_playerStateWalk_isAvailable)

    return self
end

function HosePlayer:delete()
end

function HosePlayer.inj_player_readUpdateStream(player, streamId, timestamp, connection)
    if connection:getIsServer() then
        player.lastFoundObjectIsHose = streamReadBool(streamId)
        player.lastFoundHoseIsConnected = streamReadBool(streamId)

        if player.lastFoundObjectIsHose then
            player.lastFoundHose = NetworkUtil.readNodeObjectId(streamId)
            player.lastFoundGradNodeId = streamReadUIntN(streamId, Hose.GRAB_NODES_SEND_NUM_BITS) + 1
        end
    end

end
function HosePlayer.inj_player_writeUpdateStream(player, streamId, connection, dirtyMask)
    if not connection:getIsServer() then
        streamWriteBool(streamId, player.lastFoundObjectIsHose)
        streamWriteBool(streamId, player.lastFoundHoseIsConnected)

        if player.lastFoundObjectIsHose then
            NetworkUtil.writeNodeObjectId(streamId, player.lastFoundHose)
            streamWriteUIntN(streamId, player.lastFoundGradNodeId - 1, Hose.GRAB_NODES_SEND_NUM_BITS)
        end
    end
end

function HosePlayer.inj_player_update(player, dt)
    if player.isServer then
        if player.hoseGrabNodeId ~= nil then
            local hose = NetworkUtil.getObject(player.lastFoundHose)
            hose:findConnector(player.hoseGrabNodeId)
            player.hoseIsRestricting = hose:restrictPlayerMovement(player.hoseGrabNodeId, player)

            if player.hoseIsRestricting then
                player.playerStateMachine:deactivateState("walk")
                player.playerStateMachine:deactivateState("run")
                player.playerStateMachine:activateState("idle")
            end
        end
    end
end

function HosePlayer.inj_player_onLeave(player)
    if player.isServer and player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        if player.hoseGrabNodeId ~= nil then
            hose:drop(player.hoseGrabNodeId, player)
        end
    end
end

function HosePlayer.inj_player_updateActionEvents(player)
    local eventList = player.inputInformation.registrationList
    local function disableInput(inputAction)
        -- Check if the input exists in order to prevent callstacks with mods that load dummy players (e.g. ContractorMod).
        if eventList[inputAction] ~= nil then
            local event = eventList[inputAction]
            local id = event.eventId
            g_inputBinding:setActionEventActive(id, false)
            g_inputBinding:setActionEventTextVisibility(id, false)
        end
    end

    local function enableInput(inputAction, forcePriority)
        local event = eventList[inputAction]
        local id = event.eventId
        g_inputBinding:setActionEventActive(id, true)
        g_inputBinding:setActionEventTextVisibility(id, event.textVisibility)

        if forcePriority then
            g_inputBinding:setActionEventTextPriority(id, GS_PRIO_HIGH)
        end
    end

    disableInput(InputAction.MS_ATTACH_HOSE)
    disableInput(InputAction.MS_DETACH_HOSE)
    disableInput(InputAction.MS_TOGGLE_FLOW)

    if player.hoseIsRestricting then
        disableInput(InputAction.AXIS_MOVE_FORWARD_PLAYER)
        disableInput(InputAction.AXIS_RUN)
    else
        enableInput(InputAction.AXIS_MOVE_FORWARD_PLAYER)
        enableInput(InputAction.AXIS_RUN)
    end

    if player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)

            if hose:isAttached(grabNode) and spec.foundConnectorId ~= 0 and not spec.foundConnectorIsConnected then
                enableInput(InputAction.MS_ATTACH_HOSE, true)
                local event = eventList[InputAction.MS_ATTACH_HOSE]
                local text = spec.foundConnectorIsParkPlace and g_i18n:getText("action_storeHose") or event.text
                g_inputBinding:setActionEventText(event.eventId, text)
            elseif hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    local object = desc.vehicle
                    local connector = object:getConnectorById(desc.connectorId)
                    local hasManureFlowControl = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
                    local animationName = connector.manureFlowAnimationName ~= nil and connector.manureFlowAnimationName or connector.manureFlowAnimationIndex

                    if hasManureFlowControl then
                        enableInput(InputAction.MS_TOGGLE_FLOW, true)
                        local state = object:getAnimationTime(animationName) == 0
                        local text = state and g_i18n:getText("action_toggleManureFlowStateOpen") or g_i18n:getText("action_toggleManureFlowStateClose")
                        local id = eventList[InputAction.MS_TOGGLE_FLOW].eventId

                        g_inputBinding:setActionEventText(id, g_i18n:getText("action_toggleManureFlow"):format(text))
                    end

                    if not hasManureFlowControl or not connector.hasOpenManureFlow then
                        enableInput(InputAction.MS_DETACH_HOSE, true)
                    end
                end
            end
        end
    end
end

function HosePlayer.inj_player_registerActionEvents(player)
    player.inputInformation.registrationList[InputAction.MS_ATTACH_HOSE] = { eventId = "", callback = Player.actionEventOnAttachHose, triggerUp = false, triggerDown = true, triggerAlways = false, activeType = Player.INPUT_ACTIVE_TYPE.STARTS_DISABLED, callbackState = nil, text = g_i18n:getText("input_MS_ATTACH_HOSE"), textVisibility = true }
    player.inputInformation.registrationList[InputAction.MS_DETACH_HOSE] = { eventId = "", callback = Player.actionEventOnDetachHose, triggerUp = false, triggerDown = true, triggerAlways = false, activeType = Player.INPUT_ACTIVE_TYPE.STARTS_DISABLED, callbackState = nil, text = g_i18n:getText("input_MS_DETACH_HOSE"), textVisibility = true }
    player.inputInformation.registrationList[InputAction.MS_TOGGLE_FLOW] = { eventId = "", callback = Player.actionEventOnToggleFlow, triggerUp = false, triggerDown = true, triggerAlways = false, activeType = Player.INPUT_ACTIVE_TYPE.STARTS_DISABLED, callbackState = nil, text = g_i18n:getText("input_MS_TOGGLE_FLOW"), textVisibility = true }
end

function HosePlayer.inj_player_pickUpObject(player, superFunc, grab, noEventSend)
    if player.isServer and player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)

        if grab and not hose:isConnected(grabNode) then
            hose:grab(grabNode.id, player)
        elseif player.hoseGrabNodeId ~= nil then
            hose:drop(player.hoseGrabNodeId, player)
        end
    else
        superFunc(player, grab, noEventSend)
    end
end

function HosePlayer.inj_player_checkObjectInRange(player, superFunc)
    local canHandleCheck = player.isControlled and player.isServer and not player.isCarryingObject

    if canHandleCheck then
        player.lastFoundHose = nil
        player.lastFoundGradNodeId = 0
        player.lastFoundObjectIsHose = false
        player.lastFoundHoseIsConnected = false
    end

    superFunc(player)

    if canHandleCheck then
        if player.lastFoundObject ~= nil then
            local object = g_currentMission:getNodeObject(player.lastFoundObject)
            if object ~= nil
                and object.isaHose ~= nil
                and object:isaHose() then

                local grabNode = object:getClosestGrabNode(unpack(player.lastFoundObjectHitPoint))
                local isConnected = object:isConnected(grabNode)
                if object:isDetached(grabNode) or isConnected then
                    player.lastFoundHose = NetworkUtil.getObjectId(object)
                    player.lastFoundGradNodeId = grabNode.id
                    player.lastFoundObjectIsHose = true
                    player.lastFoundHoseIsConnected = isConnected
                else
                    player.lastFoundHose = nil
                    player.lastFoundGradNodeId = 0
                    player.lastFoundObject = nil
                    player.lastFoundObjectHitPoint = nil
                    player.isObjectInRange = false
                end

                -- we raise active in order to trigger functions on the hose.
                --object:raiseHoseActive()
            end
        end
    end
end

function HosePlayer.inj_playerStateThrow_isAvailable(state, superFunc)
    if state.player.lastFoundObjectIsHose then
        return false
    end

    return superFunc(state)
end

function HosePlayer.inj_playerStatePickup_isAvailable(state, superFunc)
    local player = state.player
    if player.lastFoundObjectIsHose and player.lastFoundHoseIsConnected then
        return false
    end

    return superFunc(state)
end

function HosePlayer.inj_playerStateWalk_isAvailable(state, superFunc)
    local player = state.player
    local hose = NetworkUtil.getObject(player.lastFoundHose)

    if hose ~= nil and player.hoseGrabNodeId ~= nil then
        if player.hoseIsRestricting then
            return false
        end
    end

    return superFunc(state)
end

---- Add action event functions to the player class.
function Player.actionEventOnAttachHose(self, actionName, inputValue, callbackState, isAnalog)
    if self.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(self.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(self.lastFoundGradNodeId)

            if hose:isAttached(grabNode) then
                if spec.foundConnectorId ~= 0 and spec.foundVehicleId ~= 0 and not spec.foundConnectorIsConnected then
                    hose:attach(grabNode.id, spec.foundConnectorId, NetworkUtil.getObject(spec.foundVehicleId))
                end
            end
        end
    end
end

function Player.actionEventOnDetachHose(self, actionName, inputValue, callbackState, isAnalog)
    if self.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(self.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(self.lastFoundGradNodeId)

            if hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    hose:detach(grabNode.id, desc.connectorId, desc.vehicle)
                end
            end
        end
    end
end

function Player.actionEventOnToggleFlow(self, actionName, inputValue, callbackState, isAnalog)
    if self.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(self.lastFoundHose)

        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(self.lastFoundGradNodeId)

            if hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    local vehicle = desc.vehicle
                    local connector = vehicle:getConnectorById(desc.connectorId)
                    local hasManureFlowControl = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
                    local animationName = connector.manureFlowAnimationName ~= nil and connector.manureFlowAnimationName or connector.manureFlowAnimationIndex

                    if hasManureFlowControl and not vehicle:getIsAnimationPlaying(animationName) then
                        vehicle:setIsManureFlowOpen(desc.connectorId, not connector.hasOpenManureFlow, false)
                    end
                end
            end
        end
    end
end


-- ============================================================================
-- FS25 on-foot hose interaction (build v4, Ray custom).
-- The FS25 player is component-based, so the FS22 hooks above do not exist.
-- Here we rebuild the interaction against the real FS25 API:
--   * detection  -> player.targeter (PlayerTargeter raycast) + a hose filter
--   * per-frame  -> appended Player.update
--   * input      -> appended PlayerInputComponent.registerActionEvents
--   * grab joint -> player.hands:getKinematicNode() (kinematic helper moved
--                   from player.model onto the Hands hand tool)
-- Single-player focused: movement restriction and multiplayer netsync are
-- intentionally deferred. Everything is nil/pcall guarded so a missing API
-- logs once and no-ops instead of freezing the game (the v1 failure mode).
-- ============================================================================

HosePlayer.FS25_TARGET_MAX_DISTANCE = 5.0

function HosePlayer.installFS25(self)
    Player.update = Utils.appendedFunction(Player.update, HosePlayer.fs25_playerUpdate)

    if PlayerInputComponent ~= nil then
        PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents, HosePlayer.fs25_registerActionEvents)
        PlayerInputComponent.unregisterActionEvents = Utils.appendedFunction(PlayerInputComponent.unregisterActionEvents, HosePlayer.fs25_unregisterActionEvents)
    else
        print("[ManureSystem] HosePlayer: FS25 PlayerInputComponent not found; hose action events unavailable.")
    end
end

---Targeter filter: keep only hose objects.
function HosePlayer.fs25_targetFilter(hitNode, x, y, z)
    if hitNode == nil or g_currentMission == nil then
        return false
    end
    local object = g_currentMission:getNodeObject(hitNode)
    return object ~= nil and object.isaHose ~= nil and object:isaHose()
end

function HosePlayer.fs25_registerActionEvents(inputComponent)
    local player = inputComponent.player
    if player == nil or not player.isOwner then
        return
    end

    player.msHoseActionEvents = {}

    local ok, err = pcall(function()
        g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

        local function reg(action, callback)
            local _, eventId = g_inputBinding:registerActionEvent(action, inputComponent, callback, false, true, false, true, nil, true)
            g_inputBinding:setActionEventActive(eventId, false)
            g_inputBinding:setActionEventTextVisibility(eventId, false)
            player.msHoseActionEvents[action] = eventId
        end

        reg(InputAction.MS_ATTACH_HOSE, HosePlayer.fs25_onAttach)
        reg(InputAction.MS_DETACH_HOSE, HosePlayer.fs25_onDetach)
        reg(InputAction.MS_TOGGLE_FLOW, HosePlayer.fs25_onToggleFlow)

        g_inputBinding:endActionEventsModification()
    end)
    if not ok then
        print("[ManureSystem] HosePlayer(FS25): action-event registration error: " .. tostring(err))
    end

    if player.targeter ~= nil and CollisionFlag ~= nil then
        pcall(function()
            local mask = CollisionFlag.VEHICLE + CollisionFlag.DYNAMIC_OBJECT
            player.targeter:addTargetType(HosePlayer, mask, 0.0, HosePlayer.FS25_TARGET_MAX_DISTANCE)
            player.targeter:addFilterToTargetType(HosePlayer, HosePlayer.fs25_targetFilter)
        end)
    end
end

function HosePlayer.fs25_unregisterActionEvents(inputComponent)
    local player = inputComponent.player
    if player == nil then
        return
    end
    player.msHoseActionEvents = nil
    if player.targeter ~= nil then
        pcall(function() player.targeter:removeTargetType(HosePlayer) end)
    end
end

function HosePlayer.fs25_setActionActive(player, action, active, text)
    local events = player.msHoseActionEvents
    if events == nil then
        return
    end
    local eventId = events[action]
    if eventId == nil then
        return
    end
    g_inputBinding:setActionEventActive(eventId, active)
    g_inputBinding:setActionEventTextVisibility(eventId, active)
    if active and text ~= nil then
        g_inputBinding:setActionEventText(eventId, text)
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
    end
end

function HosePlayer.fs25_playerUpdate(player, dt)
    if not player.isOwner or not player.isControlled then
        return
    end
    local ok, err = pcall(HosePlayer.fs25_playerUpdateInternal, player, dt)
    if not ok and not player.msLoggedUpdateError then
        player.msLoggedUpdateError = true
        print("[ManureSystem] HosePlayer(FS25): update error (further errors suppressed): " .. tostring(err))
    end
end

function HosePlayer.fs25_playerUpdateInternal(player, dt)
    -- Clear all hose prompts each frame; re-enable contextually below.
    HosePlayer.fs25_setActionActive(player, InputAction.MS_ATTACH_HOSE, false)
    HosePlayer.fs25_setActionActive(player, InputAction.MS_DETACH_HOSE, false)
    HosePlayer.fs25_setActionActive(player, InputAction.MS_TOGGLE_FLOW, false)

    -- Carrying a loose hose end: keep its reference, hunt for connectors.
    if player.hoseGrabNodeId ~= nil and player.msCarriedHoseId ~= nil then
        local hose = NetworkUtil.getObject(player.msCarriedHoseId)
        if hose ~= nil then
            hose:findConnector(player.hoseGrabNodeId)
            HosePlayer.fs25_updateCarriedPrompts(player, hose)
        end
        return
    end

    -- Not carrying: look for a hose end via the targeter.
    player.lastFoundHose = nil
    player.lastFoundGradNodeId = 0
    player.lastFoundObjectIsHose = false
    player.lastFoundHoseIsConnected = false

    local targeter = player.targeter
    if targeter == nil then
        return
    end

    local node = targeter:getClosestTargetedNodeFromType(HosePlayer)
    if node == nil or not entityExists(node) then
        return
    end

    local object = g_currentMission:getNodeObject(node)
    if object == nil or object.isaHose == nil or not object:isaHose() then
        return
    end

    local wx, wy, wz = getWorldTranslation(node)
    local grabNode = object:getClosestGrabNode(wx, wy, wz)
    if grabNode == nil then
        return
    end

    local isConnected = object:isConnected(grabNode)
    if not (object:isDetached(grabNode) or isConnected) then
        return
    end

    player.lastFoundHose = NetworkUtil.getObjectId(object)
    player.lastFoundGradNodeId = grabNode.id
    player.lastFoundObjectIsHose = true
    player.lastFoundHoseIsConnected = isConnected

    if not player.msLoggedFirstDetect then
        player.msLoggedFirstDetect = true
        print("[ManureSystem] HosePlayer(FS25): hose end detected; interaction prompt enabled.")
    end

    if object:isDetached(grabNode) then
        HosePlayer.fs25_setActionActive(player, InputAction.MS_ATTACH_HOSE, true, g_i18n:getText("input_MS_ATTACH_HOSE"))
    elseif isConnected then
        HosePlayer.fs25_offerConnectedPrompts(player, object, grabNode)
    end
end

function HosePlayer.fs25_updateCarriedPrompts(player, hose)
    -- Always allow dropping while carrying.
    HosePlayer.fs25_setActionActive(player, InputAction.MS_DETACH_HOSE, true, g_i18n:getText("input_MS_DETACH_HOSE"))

    local spec = hose.spec_hose
    local grabNode = hose:getGrabNodeById(player.hoseGrabNodeId)
    if grabNode ~= nil and hose:isAttached(grabNode) and spec.foundConnectorId ~= 0 and not spec.foundConnectorIsConnected then
        local text = spec.foundConnectorIsParkPlace and g_i18n:getText("action_storeHose") or g_i18n:getText("input_MS_ATTACH_HOSE")
        HosePlayer.fs25_setActionActive(player, InputAction.MS_ATTACH_HOSE, true, text)
    end
end

function HosePlayer.fs25_offerConnectedPrompts(player, hose, grabNode)
    local spec = hose.spec_hose
    local desc = spec.grabNodesToObjects[grabNode.id]
    if desc == nil then
        return
    end
    local object = desc.vehicle
    local connector = object:getConnectorById(desc.connectorId)
    local hasFlow = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
    if hasFlow then
        HosePlayer.fs25_setActionActive(player, InputAction.MS_TOGGLE_FLOW, true, g_i18n:getText("action_toggleManureFlow"))
    end
    if not hasFlow or not connector.hasOpenManureFlow then
        HosePlayer.fs25_setActionActive(player, InputAction.MS_DETACH_HOSE, true, g_i18n:getText("input_MS_DETACH_HOSE"))
    end
end

-- MS_ATTACH_HOSE: grab a loose end, or (while carrying) attach it to a found connector.
function HosePlayer.fs25_onAttach(inputComponent, actionName, inputValue, callbackState, isAnalog)
    local player = inputComponent.player
    if player == nil then
        return
    end

    if player.hoseGrabNodeId ~= nil and player.msCarriedHoseId ~= nil then
        local hose = NetworkUtil.getObject(player.msCarriedHoseId)
        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(player.hoseGrabNodeId)
            if grabNode ~= nil and hose:isAttached(grabNode) and spec.foundConnectorId ~= 0 and spec.foundVehicleId ~= 0 and not spec.foundConnectorIsConnected then
                hose:attach(grabNode.id, spec.foundConnectorId, NetworkUtil.getObject(spec.foundVehicleId))
            end
        end
        return
    end

    if player.lastFoundObjectIsHose then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        if hose ~= nil then
            local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)
            if grabNode ~= nil and not hose:isConnected(grabNode) then
                player.msCarriedHoseId = player.lastFoundHose
                hose:grab(grabNode.id, player)
            end
        end
    end
end

-- MS_DETACH_HOSE: drop the carried end, or detach a connected end.
function HosePlayer.fs25_onDetach(inputComponent, actionName, inputValue, callbackState, isAnalog)
    local player = inputComponent.player
    if player == nil then
        return
    end

    if player.hoseGrabNodeId ~= nil and player.msCarriedHoseId ~= nil then
        local hose = NetworkUtil.getObject(player.msCarriedHoseId)
        if hose ~= nil then
            hose:drop(player.hoseGrabNodeId, player)
        end
        player.msCarriedHoseId = nil
        return
    end

    if player.lastFoundObjectIsHose and player.lastFoundHoseIsConnected then
        local hose = NetworkUtil.getObject(player.lastFoundHose)
        if hose ~= nil then
            local spec = hose.spec_hose
            local grabNode = hose:getGrabNodeById(player.lastFoundGradNodeId)
            if grabNode ~= nil and hose:isConnected(grabNode) then
                local desc = spec.grabNodesToObjects[grabNode.id]
                if desc ~= nil then
                    hose:detach(grabNode.id, desc.connectorId, desc.vehicle)
                end
            end
        end
    end
end

-- MS_TOGGLE_FLOW: open/close manure flow on the connected connector.
function HosePlayer.fs25_onToggleFlow(inputComponent, actionName, inputValue, callbackState, isAnalog)
    local player = inputComponent.player
    if player == nil then
        return
    end
    local hoseId = player.msCarriedHoseId or player.lastFoundHose
    local nodeId = player.hoseGrabNodeId or player.lastFoundGradNodeId
    if hoseId == nil or nodeId == nil then
        return
    end
    local hose = NetworkUtil.getObject(hoseId)
    if hose == nil then
        return
    end
    local spec = hose.spec_hose
    local grabNode = hose:getGrabNodeById(nodeId)
    if grabNode == nil or not hose:isConnected(grabNode) then
        return
    end
    local desc = spec.grabNodesToObjects[grabNode.id]
    if desc == nil then
        return
    end
    local vehicle = desc.vehicle
    local connector = vehicle:getConnectorById(desc.connectorId)
    local hasFlow = connector.manureFlowAnimationName ~= nil or connector.manureFlowAnimationIndex ~= nil
    local animationName = connector.manureFlowAnimationName ~= nil and connector.manureFlowAnimationName or connector.manureFlowAnimationIndex
    if hasFlow and not vehicle:getIsAnimationPlaying(animationName) then
        vehicle:setIsManureFlowOpen(desc.connectorId, not connector.hasOpenManureFlow, false)
    end
end
