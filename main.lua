local MOD_NAME = "Tear Indicator"
local VERSION = "1.2.0"

local Indicator = RegisterMod(MOD_NAME, 1)
local game = Game()
local json = require("json")

local ZERO_VECTOR = Vector(0, 0)

-- ============================================================================
-- Configuration
-- ============================================================================

local ColorPresets = {
    {
        Name = "Default",
        PlayerTear = { 0.00, 0.60, 0.95 },
        FriendlyProjectile = { 0.00, 0.60, 0.95 },
        EnemyProjectile = { 0.90, 0.15, 0.25 },
    },
    {
        Name = "Colorblind",
        PlayerTear = { 0.30, 0.50, 1.00 },
        FriendlyProjectile = { 0.30, 0.50, 1.00 },
        EnemyProjectile = { 1.00, 1.00, 1.00 },
    },
    {
        Name = "Soft White",
        PlayerTear = { 0.70, 0.85, 1.00 },
        FriendlyProjectile = { 0.70, 0.85, 1.00 },
        EnemyProjectile = { 1.00, 0.65, 0.65 },
    },
}

local DefaultConfig = {
    General = {
        Enabled = true,
        DebugText = false,
    },

    Targets = {
        PlayerTears = true,
        FriendlyProjectiles = false,
        EnemyProjectiles = true,
    },

    Colors = {
        Preset = 1,

        -- When true, the manual RGB values below are used instead of the preset.
        UseCustom = false,

        Custom = {
        Name = "Default",
            PlayerTear = { 0.00, 0.60, 0.95 },
            FriendlyProjectile = { 0.00, 0.60, 0.95 },
            EnemyProjectile = { 0.90, 0.15, 0.25 },
        },
    },

    Filters = {
        -- 0 means no height filtering.
        HeightThreshold = 45,

        -- If true, raw Height is allowed to act as a "future peak" hint.
        -- This is what lets many high-arc tears be marked from their start.
        UseRawHeightAsPeakHint = true,

        -- 0 means unlimited.
        MaxActiveIndicators = 80,
    },

    Marker = {
        -- "Always", "Only for high arches", "Only for low arches", or "Disabled".
        -- The high/low arch modes use the height threshold to decide.
        Visibility = "Only for high arches",

        AlphaBottom = 0.85,
        AlphaTop = 0.40,
        ScaleBottom = 0.55,
        ScaleTop = 0.20,

        -- Current air height at which alpha/scale reach their bottom values.
        HeightForBottomValues = 25,

        -- Current air height at which alpha/scale reach their top values.
        HeightForTopValues = 200,
    },

    CenterDot = {
        -- "Always", "Only for high arches", "Only for low arches", or "Disabled".
        -- The high/low arch modes use the height threshold to decide.
        Visibility = "Only for low arches",

        AlphaBottom = 0.70,
        AlphaTop = 0.30,
        ScaleBottom = 0.60,
        ScaleTop = 0.45,

        -- Current air height at which alpha/scale reach their bottom values.
        HeightForBottomValues = 25,

        -- Current air height at which alpha/scale reach their top values.
        HeightForTopValues = 200,
    },

    Tether = {
        -- "Always", "Only for high arches", "Only for low arches", or "Disabled".
        -- The high/low arch modes use the height threshold to decide.
        Visibility = "Only for high arches",

        -- Removes short tethers.
        MinLength = 0,

        -- Removes tethers which are too long.
        -- 0 means unlimited.
        MaxLength = 200,

        -- Offsets the top end of the tether relative to the projectiles.
        -- Positive values move the ends down.
        TopYOffset = 6,

        -- Offsets the bottom end relative to the ground.
        BottomYOffset = 0,

        -- Sprite spacing
        Step = 5.75,

        -- Vertical sprite scale
        Height = 0.40,

        AlphaBottom = 1.00,
        AlphaTop = 0.00,
        WidthBottom = 0.30,
        WidthTop = 0.30,

        -- Current air height at which alpha/scale reach their minimum values.
        HeightForBottomValues = 40,

        -- Current air height at which alpha/scale reach their maximum values.
        HeightForTopValues = 200,

        -- Uses the projectile's visual offset for tether placement.
        UsePositionOffset = true,
    },

    Trail = {
        -- "Always", "Only for high arches", "Only for low arches", or "Disabled".
        -- The high/low arch modes use the height threshold to decide.
        Visibility = "Always",

        Length = 5,
        SampleEveryNFrames = 1,
        MinDistance = 10.00,

        -- Positive values push trail samples farther away from the current
        -- marker center along the trail direction.
        OffsetFromMarkerCenter = 0,

        AlphaBottom = 1.00,
        AlphaTop = 1.00,
        ScaleBottom = 0.15,
        ScaleTop = 0.15,

        -- Current air height at which alpha/scale reach their bottom values.
        HeightForBottomValues = 25,

        -- Current air height at which alpha/scale reach their top values.
        HeightForTopValues = 200,

    },

    HeightText = {
        -- "Always", "Only for high arches", "Only for low arches", or "Disabled".
        -- The high/low arch modes use the height threshold to decide.
        Visibility = "Disabled",

        MinHeight = 0,

        OffsetX = 8,
        OffsetY = -6,

        Scale = 0.70,
        Alpha = 0.90,
        Decimals = 0,

        UsePositionOffset = true,
    },

    Sprites = {
        Enabled = true,
        FallbackToText = true,

        Anm2Path = "gfx/indicator/indicators.anm2",
        PngPath = "gfx/indicator/indicators.png",
    },

    Cleanup = {
        StaleFrames = 20,
    },
}

---@type table
local Config = nil

-- ============================================================================
-- Small utilities
-- ============================================================================

local function clamp(x, minValue, maxValue)
    if x < minValue then return minValue end
    if x > maxValue then return maxValue end
    return x
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function formatNumber(x, decimals)
    decimals = decimals or 0

    if decimals <= 0 then
        return tostring(math.floor(x + 0.5))
    end

    return string.format("%." .. tostring(decimals) .. "f", x)
end

local function roundNumber(x, decimals)
    decimals = decimals or 0
    local mult = 10 ^ decimals
    return math.floor(x * mult + 0.5) / mult
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for k, v in pairs(value) do
        copied[k] = deepCopy(v)
    end
    return copied
end

-- Recursively copy src into dest while preserving the identity of dest and any
-- existing nested tables. This matters because the Mod Config Menu captures
-- color tables (e.g. Config.Colors.Custom.PlayerTear) by reference for title
-- tinting; replacing Config wholesale would orphan those references.
local function assignInto(dest, src)
    for k in pairs(dest) do
        if src[k] == nil then
            dest[k] = nil
        end
    end

    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dest[k]) ~= "table" then
                dest[k] = {}
            end
            assignInto(dest[k], v)
        else
            dest[k] = v
        end
    end
end

local function mergeConfig(defaults, saved)
    if type(saved) ~= "table" then
        return defaults
    end

    for k, v in pairs(saved) do
        if type(defaults[k]) == "table" and type(v) == "table" then
            mergeConfig(defaults[k], v)
        elseif defaults[k] ~= nil and type(defaults[k]) == type(v) then
            defaults[k] = v
        end
    end

    return defaults
end

local function getNestedValue(root, path)
    local current = root

    for i = 1, #path do
        if type(current) ~= "table" then
            return nil
        end

        current = current[path[i]]
    end

    return current
end

local function setNestedValue(root, path, value)
    local current = root

    for i = 1, #path - 1 do
        if type(current) ~= "table" then
            return
        end

        current = current[path[i]]
    end

    if type(current) ~= "table" then
        return
    end

    current[path[#path]] = value
end

local function getColorPreset()
    if Config.Colors.UseCustom then
        return Config.Colors.Custom
    end

    return ColorPresets[Config.Colors.Preset] or ColorPresets[1]
end

local function getBoolText(value)
    return value and "On" or "Off"
end

local function getYesNoText(value)
    return value and "Yes" or "No"
end

-- The ordered list of indicator visibility modes shown in the Mod Config Menu.
local VisibilityOptions = {
    "Always",
    "Only for high arches",
    "Only for low arches",
    "Disabled",
}

local function visibilityIndex(value)
    for i = 1, #VisibilityOptions do
        if VisibilityOptions[i] == value then
            return i
        end
    end

    return 1
end

-- ============================================================================
-- Save/load
-- ============================================================================

local function saveConfig()
    if Config == nil then
        return
    end

    Indicator:SaveData(json.encode({
        Version = VERSION,
        Config = Config,
    }))
end

local function loadConfig()
    Config = deepCopy(DefaultConfig)

    if not Indicator:HasData() then
        return
    end

    local ok, decoded = pcall(function()
        return json.decode(Indicator:LoadData())
    end)

    if not ok or type(decoded) ~= "table" then
        return
    end

    local savedConfig = decoded.Config or decoded
    Config = mergeConfig(deepCopy(DefaultConfig), savedConfig)

    -- Backwards compatibility for 0.4.x CenterDot settings.
    if type(savedConfig) == "table" and type(savedConfig.CenterDot) == "table" then
        if type(savedConfig.CenterDot.Alpha) == "number" then
            Config.CenterDot.AlphaTop = savedConfig.CenterDot.Alpha
        end

        if type(savedConfig.CenterDot.Scale) == "number" then
            Config.CenterDot.ScaleTop = savedConfig.CenterDot.Scale
        end
    end

    -- Preserve old tether appearance if Width did not exist yet.
    if type(savedConfig) == "table" and type(savedConfig.Tether) == "table" then
        if type(savedConfig.Tether.Scale) == "number" and type(savedConfig.Tether.Width) ~= "number" then
            Config.Tether.Width = savedConfig.Tether.Scale
        end
    end
end

local function resetRuntimeData()
    -- Forward declaration target. Defined later.
end

loadConfig()

-- ============================================================================
-- Coordinate/render helpers
-- ============================================================================

-- In the Mirrored World the sprites' screen X has to be mirrored to match.
local function isMirrorWorld()
    local room = game:GetRoom()

    if room ~= nil and room.IsMirrorWorld ~= nil then
        return room:IsMirrorWorld()
    end

    return false
end

local function worldToScreen(pos)
    local screenPos

    if Isaac.WorldToScreen ~= nil then
        screenPos = Isaac.WorldToScreen(pos)
    else
        local room = game:GetRoom()
        if room ~= nil and room.WorldToScreenPosition ~= nil then
            screenPos = room:WorldToScreenPosition(pos)
        else
            screenPos = pos
        end
    end

    if isMirrorWorld() then
        screenPos = Vector(Isaac.GetScreenWidth() - screenPos.X, screenPos.Y)
    end

    return screenPos
end

local function renderText(text, x, y, scaleX, scaleY, r, g, b, a)
    if Isaac.RenderScaledText ~= nil then
        Isaac.RenderScaledText(text, x, y, scaleX, scaleY, r, g, b, a)
    else
        Isaac.RenderText(text, x, y, r, g, b, a)
    end
end

local function drawCenteredText(text, screenPos, scaleX, rgb, alpha, scaleY)
    scaleX = scaleX or 1
    scaleY = scaleY or scaleX

    local approxWidth = #text * 6 * scaleX
    local approxHeight = 8 * scaleY

    renderText(
        text,
        screenPos.X - approxWidth * 0.5,
        screenPos.Y - approxHeight * 0.5,
        scaleX,
        scaleY,
        rgb[1],
        rgb[2],
        rgb[3],
        alpha
    )
end

-- ============================================================================
-- Sprite rendering
-- ============================================================================

local indicatorSprites = nil
local spriteLoadAttempted = false
local spritesAvailable = false

local FallbackGlyphs = {
    Marker = "O",
    Center = "+",
    Trail = ".",
    Tether = "I",
}

local function makeIndicatorSprite(animationName)
    local sprite = Sprite()

    sprite:Load(Config.Sprites.Anm2Path, false)
    sprite:ReplaceSpritesheet(0, Config.Sprites.PngPath)
    sprite:LoadGraphics()

    sprite:SetFrame(animationName, 0)
    sprite.Color = Color(1, 1, 1, 1)
    sprite.Scale = Vector(1, 1)

    return sprite
end

local function initIndicatorSprites()
    if spriteLoadAttempted then
        return spritesAvailable
    end

    spriteLoadAttempted = true

    local ok, result = pcall(function()
        indicatorSprites = {
            Marker = makeIndicatorSprite("Marker"),
            Center = makeIndicatorSprite("Center"),
            Trail = makeIndicatorSprite("Trail"),
            Tether = makeIndicatorSprite("Tether"),
        }

        return
            indicatorSprites.Marker ~= nil and indicatorSprites.Marker:IsLoaded() and
            indicatorSprites.Center ~= nil and indicatorSprites.Center:IsLoaded() and
            indicatorSprites.Trail ~= nil and indicatorSprites.Trail:IsLoaded() and
            indicatorSprites.Tether ~= nil and indicatorSprites.Tether:IsLoaded()
    end)

    if not ok or not result then
        Isaac.DebugString(MOD_NAME .. ": sprite loading failed")
        indicatorSprites = nil
        spritesAvailable = false
        return false
    end

    spritesAvailable = true
    Isaac.DebugString(MOD_NAME .. ": indicator sprites loaded")
    return true
end

local function drawIndicatorSprite(name, screenPos, spriteScaleX, spriteScaleY, rgb, alpha, fallbackTextScaleX, fallbackTextScaleY)
    local scaleX = spriteScaleX or 1
    local scaleY = spriteScaleY or scaleX

    if Config.Sprites.Enabled and initIndicatorSprites() then
        ---@diagnostic disable-next-line: need-check-nil
        local sprite = indicatorSprites[name]

        if sprite ~= nil then
            sprite.Color = Color(rgb[1], rgb[2], rgb[3], alpha)
            sprite.Scale = Vector(scaleX, scaleY)
            sprite.Rotation = 0
            sprite:Render(screenPos, ZERO_VECTOR, ZERO_VECTOR)
            return
        end
    end

    if Config.Sprites.FallbackToText then
        drawCenteredText(
            FallbackGlyphs[name] or "?",
            screenPos,
            fallbackTextScaleX or 1,
            rgb,
            alpha,
            fallbackTextScaleY
        )
    end
end

-- ============================================================================
-- Entity classification / height logic
-- ============================================================================

local function getEntityKey(entity)
    if GetPtrHash ~= nil then
        return tostring(GetPtrHash(entity)) .. ":" .. tostring(entity.InitSeed)
    end

    return tostring(entity.InitSeed)
end

local function classifyEntity(entity)
    if entity.Type == EntityType.ENTITY_TEAR then
        return "tear"
    end

    if EntityType.ENTITY_PROJECTILE ~= nil and entity.Type == EntityType.ENTITY_PROJECTILE then
        return "projectile"
    end

    return nil
end

local function isFriendlyProjectile(entity)
    if entity.Type == EntityType.ENTITY_TEAR then
        return true
    end

    if entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) then
        return true
    end

    if entity.SpawnerType == EntityType.ENTITY_PLAYER then
        return true
    end

    if entity.SpawnerType == EntityType.ENTITY_FAMILIAR then
        return true
    end

    return false
end

-- Familiars fire ENTITY_TEAR, which are classified as "tear" rather than "projectile".
-- They are their tears spawner which allows routing them to the Frinedly category.
local function isFamiliarTear(entity)
    return entity.SpawnerType == EntityType.ENTITY_FAMILIAR
end

local function getVisualColor(entity, kind)
    local preset = getColorPreset()

    if kind == "tear" then
        if isFamiliarTear(entity) then
            return preset.FriendlyProjectile
        end

        return preset.PlayerTear
    end

    if isFriendlyProjectile(entity) then
        return preset.FriendlyProjectile
    end

    return preset.EnemyProjectile
end

local function passesBaseFilters(entity, kind)
    if entity == nil or not entity:Exists() then
        return false
    end

    if not entity.Visible then
        return false
    end

    if kind == "tear" then
        if isFamiliarTear(entity) then
            return Config.Targets.FriendlyProjectiles
        end

        return Config.Targets.PlayerTears
    end

    if kind == "projectile" then
        local friendly = isFriendlyProjectile(entity)

        if friendly then
            return Config.Targets.FriendlyProjectiles
        end

        return Config.Targets.EnemyProjectiles
    end

    return false
end

local function getRawHeight(entity)
    local h = nil

    if entity.Type == EntityType.ENTITY_TEAR then
        local tear = entity:ToTear()
        if tear ~= nil and tear.Height ~= nil then
            h = tear.Height
        end
    elseif EntityType.ENTITY_PROJECTILE ~= nil and entity.Type == EntityType.ENTITY_PROJECTILE then
        local projectile = entity:ToProjectile()
        if projectile ~= nil and projectile.Height ~= nil then
            h = projectile.Height
        end
    end

    if h == nil and entity.Height ~= nil then
        h = entity.Height
    end

    return h or 0
end

local function getPositionOffsetAirHeight(entity)
    if entity.PositionOffset ~= nil and entity.PositionOffset.Y < -0.01 then
        return -entity.PositionOffset.Y, true
    end

    return 0, false
end

local function getCurrentAirHeight(entity)
    local poHeight, hasPositionOffsetHeight = getPositionOffsetAirHeight(entity)

    if hasPositionOffsetHeight then
        return poHeight
    end

    return math.abs(getRawHeight(entity))
end

local function getHeightQualificationCandidate(entity)
    local currentHeight = getCurrentAirHeight(entity)

    if Config.Filters.UseRawHeightAsPeakHint then
        return math.max(currentHeight, math.abs(getRawHeight(entity)))
    end

    return currentHeight
end

-- ============================================================================
-- Runtime tracking
-- ============================================================================

local entityStates = {}

resetRuntimeData = function()
    entityStates = {}
end

local function getOrCreateEntityState(entity, kind)
    local key = getEntityKey(entity)
    local frame = game:GetFrameCount()

    local state = entityStates[key]

    if state == nil then
        state = {
            Key = key,
            Kind = kind,

            SpawnFrame = frame,
            LastSeenFrame = frame,

            HighestCandidateHeight = 0,
            HeightQualified = false,

            IndicatorActive = false,
            IndicatorSlotFrame = nil,

            Points = {},
            LastSampleFrame = -999999,
        }

        entityStates[key] = state
    end

    state.Kind = kind
    state.LastSeenFrame = frame

    local candidateHeight = getHeightQualificationCandidate(entity)
    if candidateHeight > state.HighestCandidateHeight then
        state.HighestCandidateHeight = candidateHeight
    end

    local threshold = Config.Filters.HeightThreshold or 0
    state.HeightQualified =
        threshold <= 0 or state.HighestCandidateHeight >= threshold

    return state
end

local function recordTrailPoint(entity, state)
    if Config.Trail.Visibility == "Disabled" then
        return
    end

    local trailLength = math.floor(Config.Trail.Length or 0)
    if trailLength <= 0 then
        return
    end

    local frame = game:GetFrameCount()

    if frame - state.LastSampleFrame < (Config.Trail.SampleEveryNFrames or 1) then
        return
    end

    local points = state.Points
    local shouldSample = false

    if #points == 0 then
        shouldSample = true
    else
        local last = points[#points]
        local delta = entity.Position - last
        local minDistance = Config.Trail.MinDistance or 0

        if delta:LengthSquared() >= minDistance * minDistance then
            shouldSample = true
        end
    end

    if not shouldSample then
        return
    end

    table.insert(points, Vector(entity.Position.X, entity.Position.Y))
    state.LastSampleFrame = frame

    while #points > trailLength do
        table.remove(points, 1)
    end
end

local function pruneEntityStates()
    local frame = game:GetFrameCount()
    local staleFrames = Config.Cleanup.StaleFrames or 20

    for key, state in pairs(entityStates) do
        if frame - state.LastSeenFrame > staleFrames then
            entityStates[key] = nil
        end
    end
end

local function updateIndicatorSlots()
    local maxActive = math.floor(Config.Filters.MaxActiveIndicators or 0)
    local frame = game:GetFrameCount()

    if maxActive <= 0 then
        for _, state in pairs(entityStates) do
            if state.HeightQualified then
                if not state.IndicatorActive then
                    state.IndicatorSlotFrame = frame
                end

                state.IndicatorActive = true
            else
                state.IndicatorActive = false
                state.IndicatorSlotFrame = nil
            end
        end

        return
    end

    local active = {}

    for _, state in pairs(entityStates) do
        if state.IndicatorActive and state.HeightQualified then
            table.insert(active, state)
        else
            state.IndicatorActive = false
            state.IndicatorSlotFrame = nil
        end
    end

    table.sort(active, function(a, b)
        local aSlot = a.IndicatorSlotFrame or a.SpawnFrame
        local bSlot = b.IndicatorSlotFrame or b.SpawnFrame

        if aSlot == bSlot then
            return a.Key < b.Key
        end

        return aSlot < bSlot
    end)

    for i = maxActive + 1, #active do
        active[i].IndicatorActive = false
        active[i].IndicatorSlotFrame = nil
    end

    local activeCount = math.min(#active, maxActive)

    if activeCount >= maxActive then
        return
    end

    local candidates = {}

    for _, state in pairs(entityStates) do
        if state.HeightQualified and not state.IndicatorActive then
            table.insert(candidates, state)
        end
    end

    table.sort(candidates, function(a, b)
        if a.SpawnFrame == b.SpawnFrame then
            return a.Key < b.Key
        end

        return a.SpawnFrame < b.SpawnFrame
    end)

    for _, state in ipairs(candidates) do
        if activeCount >= maxActive then
            break
        end

        state.IndicatorActive = true
        state.IndicatorSlotFrame = frame
        activeCount = activeCount + 1
    end
end

-- ============================================================================
-- Indicator rendering
-- ============================================================================

local function shouldRenderIndicatorPart(visibility, state)
    if visibility == "Disabled" then
        return false
    end

    -- A height-qualified, slot-active entity counts as a "high arch".
    local isHighArch = state ~= nil and state.IndicatorActive

    if visibility == "Only for high arches" then
        return isHighArch
    end

    if visibility == "Only for low arches" then
        return not isHighArch
    end

    -- "Always" (and any unexpected value) renders unconditionally.
    return true
end

local function shouldRenderMarker(state)
    return shouldRenderIndicatorPart(Config.Marker.Visibility, state)
end

local function shouldRenderCenterDot(state)
    return shouldRenderIndicatorPart(Config.CenterDot.Visibility, state)
end

local function shouldRenderTrail(state)
    return shouldRenderIndicatorPart(Config.Trail.Visibility, state)
end

local function shouldRenderTether(state)
    return shouldRenderIndicatorPart(Config.Tether.Visibility, state)
end

local function shouldRenderHeightText(state)
    return shouldRenderIndicatorPart(Config.HeightText.Visibility, state)
end

local function getHeightLerpValue(currentHeight, HeightForBottomValues, HeightForTopValues)
    HeightForBottomValues = HeightForBottomValues or 0

    -- If the range is empty or inverted, snap straight to the max values.
    if HeightForTopValues == nil or HeightForTopValues <= HeightForBottomValues then
        return 1
    end

    local span = HeightForTopValues - HeightForBottomValues
    return clamp(((currentHeight or 0) - HeightForBottomValues) / span, 0, 1)
end

local function getTrailPointWithCenterOffset(point, centerPos)
    local offset = Config.Trail.OffsetFromMarkerCenter or 0

    if math.abs(offset) < 0.01 then
        return point
    end

    local dx = point.X - centerPos.X
    local dy = point.Y - centerPos.Y
    local distance = math.sqrt(dx * dx + dy * dy)

    if distance < 0.01 then
        return point
    end

    local adjustedDistance = math.max(0, distance + offset)

    return Vector(
        centerPos.X + dx / distance * adjustedDistance,
        centerPos.Y + dy / distance * adjustedDistance
    )
end

local function renderTrail(entity, state, rgb, alpha, scale)
    if state == nil then
        return
    end

    local points = state.Points
    local count = #points

    if count <= 1 then
        return
    end

    local drawableCount = count - 1
    local centerPos = entity.Position

    for i = 1, drawableCount do
        local p = getTrailPointWithCenterOffset(points[i], centerPos)
        local f = i / drawableCount

        local alphaFaded = alpha * f
        local spriteScaleFaded = scale * f

        local textScale = 0.90 * f

        drawIndicatorSprite(
            "Trail",
            worldToScreen(p),
            spriteScaleFaded,
            nil,
            rgb,
            alphaFaded,
            textScale
        )
    end
end

local function getProjectileVisualScreenPos(entity, groundScreenPos, usePositionOffset)
    if usePositionOffset == nil then
        usePositionOffset = true
    end

    local rawHeight = getRawHeight(entity)

    if usePositionOffset and entity.PositionOffset ~= nil then
        local po = entity.PositionOffset

        if math.abs(po.X) > 0.01 or math.abs(po.Y) > 0.01 then
            local visualScreenPos = worldToScreen(entity.Position + po)
            local apparentHeight = groundScreenPos.Y - visualScreenPos.Y

            if apparentHeight > 0.01 then
                return visualScreenPos, apparentHeight
            end
        end
    end

    local airHeight = math.abs(rawHeight)
    local visualY = groundScreenPos.Y - airHeight

    if rawHeight < 0 then
        visualY = groundScreenPos.Y + rawHeight
    end

    return Vector(groundScreenPos.X, visualY), airHeight
end

local function renderTether(entity, state, rgb, groundScreenPos, alpha, width)
    if state == nil then
        return
    end

    local visualScreenPos = getProjectileVisualScreenPos(
        entity,
        groundScreenPos,
        Config.Tether.UsePositionOffset
    )

    local topY = visualScreenPos.Y + (Config.Tether.TopYOffset or 0)
    local bottomY = groundScreenPos.Y + (Config.Tether.BottomYOffset or 0)
    local length = bottomY - topY

    if length < (Config.Tether.MinLength or 0) then
        return
    end

    local maxLength = Config.Tether.MaxLength or 0
    if maxLength > 0 and length > maxLength then
        topY = bottomY - maxLength
    end

    local x = groundScreenPos.X
    local y = topY

    local step = Config.Tether.Step or 4
    if step <= 0 then
        step = 4
    end

    local tetherScaleX = width
    local tetherScaleY = Config.Tether.Height

    while y <= bottomY do
        drawIndicatorSprite(
            "Tether",
            Vector(x, y),
            tetherScaleX,
            tetherScaleY,
            rgb,
            alpha,
            0.7
        )

        y = y + step
    end
end

local function renderHeightText(entity, state, rgb, groundScreenPos)
    if not shouldRenderHeightText(state) then
        return
    end

    local height = getCurrentAirHeight(entity)

    if height < (Config.HeightText.MinHeight or 0) then
        return
    end

    local visualScreenPos = getProjectileVisualScreenPos(
        entity,
        groundScreenPos,
        Config.HeightText.UsePositionOffset
    )

    local decimals = math.floor((Config.HeightText.Decimals or 0) + 0.5)
    decimals = clamp(decimals, 0, 2)

    local text = formatNumber(height, decimals)
    local scale = Config.HeightText.Scale or 0.7
    local alpha = Config.HeightText.Alpha or 0.9

    local x = visualScreenPos.X + (Config.HeightText.OffsetX or 0)
    local y = visualScreenPos.Y + (Config.HeightText.OffsetY or 0)

    -- Small shadow for readability.
    renderText(
        text,
        x + 1,
        y + 1,
        scale,
        scale,
        0,
        0,
        0,
        alpha * 0.75
    )

    renderText(
        text,
        x,
        y,
        scale,
        scale,
        rgb[1],
        rgb[2],
        rgb[3],
        alpha
    )
end

local function shouldRenderEntity(entity, kind, state)
    if not passesBaseFilters(entity, kind) then
        return false
    end

    return
        shouldRenderMarker(state) or
        shouldRenderCenterDot(state) or
        shouldRenderTrail(state) or
        shouldRenderTether(state) or
        shouldRenderHeightText(state)
end

local function renderEntityIndicator(entity, kind, state)
    local rgb = getVisualColor(entity, kind)
    local groundScreenPos = worldToScreen(entity.Position)
    local currentHeight = getCurrentAirHeight(entity)

    if shouldRenderMarker(state) then
        local t = getHeightLerpValue(
            currentHeight,
            Config.Marker.HeightForBottomValues,
            Config.Marker.HeightForTopValues
        )

        local alpha = lerp(Config.Marker.AlphaBottom, Config.Marker.AlphaTop, t)
        local scale = lerp(Config.Marker.ScaleBottom, Config.Marker.ScaleTop, t)

        drawIndicatorSprite(
            "Marker",
            groundScreenPos,
            scale,
            nil,
            rgb,
            alpha,
            1.00
        )
    end

    if shouldRenderCenterDot(state) then
        local t = getHeightLerpValue(
            currentHeight,
            Config.CenterDot.HeightForBottomValues,
            Config.CenterDot.HeightForTopValues
        )

        local alpha = lerp(Config.CenterDot.AlphaBottom, Config.CenterDot.AlphaTop, t)
        local scale = lerp(Config.CenterDot.ScaleBottom, Config.CenterDot.ScaleTop, t)

        drawIndicatorSprite(
            "Center",
            groundScreenPos,
            scale,
            nil,
            rgb,
            alpha,
            0.75
        )
    end

    if shouldRenderTrail(state) then
        local t = getHeightLerpValue(
            currentHeight,
            Config.Trail.HeightForBottomValues,
            Config.Trail.HeightForTopValues
        )

        local alpha = lerp(Config.Trail.AlphaBottom, Config.Trail.AlphaTop, t)
        local scale = lerp(Config.Trail.ScaleBottom, Config.Trail.ScaleTop, t)

        renderTrail(
            entity,
            state,
            rgb,
            alpha,
            scale
        )
    end

    if shouldRenderTether(state) then
        local t = getHeightLerpValue(
            currentHeight,
            Config.Tether.HeightForBottomValues,
            Config.Tether.HeightForTopValues
        )

        local alpha = lerp(Config.Tether.AlphaBottom, Config.Tether.AlphaTop, t)
        local width = lerp(Config.Tether.WidthBottom, Config.Tether.WidthTop, t)

        renderTether(
            entity,
            state,
            rgb,
            groundScreenPos,
            alpha,
            width
        )
    end

    renderHeightText(entity, state, rgb, groundScreenPos)
end

-- ============================================================================
-- Mod Config Menu - Impure support
-- ============================================================================

local mcmRegistered = false

local function getModConfigMenu()
    if MCM ~= nil then
        return MCM
    end

    if ModConfigMenu ~= nil then
        return ModConfigMenu
    end

    return nil
end

local function mcmAddTitle(menu, tab, text, color)
    if menu.AddTitle ~= nil then
        menu.AddTitle(MOD_NAME, tab, text, color)
    end
end

local function mcmAddText(menu, tab, text, color)
    if menu.AddText ~= nil then
        menu.AddText(MOD_NAME, tab, text, color)
    end
end

local function mcmAddSpace(menu, tab)
    if menu.AddSpace ~= nil then
        menu.AddSpace(MOD_NAME, tab)
    end
end

local function onConfigChanged(afterChange)
    saveConfig()

    if afterChange ~= nil then
        afterChange()
    end
end

local function addBooleanSetting(menu, tab, label, path, info, afterChange)
    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.BOOLEAN,

        CurrentSetting = function()
            return getNestedValue(Config, path)
        end,

        Display = function()
            return label .. ": " .. getBoolText(getNestedValue(Config, path))
        end,

        OnChange = function(value)
            setNestedValue(Config, path, value)
            onConfigChanged(afterChange)
        end,

        Info = info,
    })
end

local function addYesNoSetting(menu, tab, label, path, info, afterChange)
    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.BOOLEAN,

        CurrentSetting = function()
            return getNestedValue(Config, path)
        end,

        Display = function()
            return label .. ": " .. getYesNoText(getNestedValue(Config, path))
        end,

        OnChange = function(value)
            setNestedValue(Config, path, value)
            onConfigChanged(afterChange)
        end,

        Info = info,
    })
end

local function addVisibilitySetting(menu, tab, label, path, info, afterChange)
    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.NUMBER,
        Minimum = 1,
        Maximum = #VisibilityOptions,
        ModifyBy = 1,

        CurrentSetting = function()
            return visibilityIndex(getNestedValue(Config, path))
        end,

        Display = function()
            local index = visibilityIndex(getNestedValue(Config, path))
            return label .. ": " .. VisibilityOptions[index]
        end,

        OnChange = function(value)
            local index = clamp(math.floor((value or 1) + 0.5), 1, #VisibilityOptions)
            setNestedValue(Config, path, VisibilityOptions[index])
            onConfigChanged(afterChange)
        end,

        Info = info,
    })
end

local function addNumberSetting(menu, tab, label, path, minValue, maxValue, step, decimals, info, afterChange)
    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.NUMBER,
        Minimum = minValue,
        Maximum = maxValue,
        ModifyBy = step or 1,

        CurrentSetting = function()
            return getNestedValue(Config, path)
        end,

        Display = function()
            local value = getNestedValue(Config, path) or 0
            return label .. ": " .. tostring(roundNumber(value, decimals or 0))
        end,

        OnChange = function(value)
            value = clamp(value or minValue, minValue, maxValue)

            if decimals ~= nil and decimals > 0 then
                value = roundNumber(value, decimals)
            else
                value = math.floor(value + 0.5)
            end

            setNestedValue(Config, path, value)
            onConfigChanged(afterChange)
        end,

        Info = info,
    })
end

local function addColorPresetSetting(menu)
    menu.AddSetting(MOD_NAME, "Colors", {
        Type = menu.OptionType.NUMBER,
        Minimum = 1,
        Maximum = #ColorPresets,
        ModifyBy = 1,

        CurrentSetting = function()
            return Config.Colors.Preset
        end,

        Display = function()
            local preset = ColorPresets[Config.Colors.Preset] or ColorPresets[1]
            return preset.Name
        end,

        OnChange = function(value)
            Config.Colors.Preset = clamp(math.floor(value + 0.5), 1, #ColorPresets)
            saveConfig()
        end,

        Info = {
            "Changes the colors used for player tears, friendly projectiles, and enemy projectiles.",
        },
    })
end

local function addResetDefaultsSetting(menu)
    menu.AddSetting(MOD_NAME, "General", {
        Type = menu.OptionType.BOOLEAN,

        CurrentSetting = function()
            return false
        end,

        Display = function()
            return "Reset all Tear Indicator settings"
        end,

        OnChange = function()
            -- Reset in place so MCM-captured color table references (used to
            -- tint the Colors tab titles) keep pointing at the live config.
            assignInto(Config, DefaultConfig)
            saveConfig()
            resetRuntimeData()

            -- Sprites may have changed paths/settings.
            indicatorSprites = nil
            spriteLoadAttempted = false
            spritesAvailable = false
        end,

        Info = {
            "Resets all settings to their defaults.",
        },
    })
end

local function setupModConfigMenu()
    if mcmRegistered then
        return
    end

    local menu = getModConfigMenu()
    if menu == nil or menu.AddSetting == nil or menu.OptionType == nil then
        return
    end

    if menu.RemoveCategory ~= nil then
        menu.RemoveCategory(MOD_NAME)
    end

    if menu.SetCategoryInfo ~= nil then
        menu.SetCategoryInfo(
            MOD_NAME,
            "Ground markers and tethers for arcing tears/projectiles."
        )
    end

    -- General
    mcmAddTitle(menu, "General", MOD_NAME)

    mcmAddText(menu, "General", "Version " .. VERSION)
    mcmAddSpace(menu, "General")

    addBooleanSetting(menu, "General", "Enabled", { "General", "Enabled" }, {
        "Toggle the mod",
    })

    mcmAddSpace(menu, "General")
    mcmAddSpace(menu, "General")

    addVisibilitySetting(menu, "General", "Projectile heights", { "HeightText", "Visibility" }, {
        "Shows the height of projectiles next to them.",
        "You can use this to conifgure the mod more easily."
    })

    mcmAddSpace(menu, "General")

    addResetDefaultsSetting(menu)

    -- Filters / performance
    mcmAddTitle(menu, "Filters", "Categories")

    addYesNoSetting(menu, "Filters", "Player tears", { "Targets", "PlayerTears" }, {
        "Show indicators for player tears.",
    }, resetRuntimeData)

    addYesNoSetting(menu, "Filters", "Friendly tears", { "Targets", "FriendlyProjectiles" }, {
        "Show indicators for tears from familiars.",
    }, resetRuntimeData)

    addYesNoSetting(menu, "Filters", "Enemy projectiles", { "Targets", "EnemyProjectiles" }, {
        "Show indicators for enemy projectiles.",
    }, resetRuntimeData)

    mcmAddSpace(menu, "Filters")

    mcmAddTitle(menu, "Filters", "Filters")

    addNumberSetting(menu, "Filters", "Height threshold", { "Filters", "HeightThreshold" }, 0, 96, 1, 0, {
        "Indicators with \"Only for high arcs\" enabled, are only rendered for projectiles which will reach this height.",
    }, resetRuntimeData)

    addYesNoSetting(menu, "Filters", "Mark from start to end", { "Filters", "UseRawHeightAsPeakHint" }, {
        "Marks projectiles that will reach the height threshold while they are still rising toward it,",
        "and keeps them marked as they fall back below it.",
    }, resetRuntimeData)

    addNumberSetting(menu, "Filters", "Max active indicators", { "Filters", "MaxActiveIndicators" }, 0, 200, 5, 0, {
        "Caps the number of indicators rendered at once.",
        "0 means unlimited.",
    }, resetRuntimeData)

    -- Colors
    mcmAddTitle(menu, "Colors", "Presets")

    addColorPresetSetting(menu)

    mcmAddSpace(menu, "Colors")

    mcmAddTitle(menu, "Colors", "Custom colors")

    addYesNoSetting(menu, "Colors", "Enabled", { "Colors", "UseCustom" }, {
        "Use your own colors instead of the presets.",
    })

    mcmAddSpace(menu, "Colors")

    mcmAddTitle(menu, "Colors", "Player:", Config.Colors.Custom.PlayerTear)

    addNumberSetting(menu, "Colors", "Red", {
        "Colors", "Custom", "PlayerTear", 1
        }, 0, 1, 0.05, 2
    )

    addNumberSetting(menu, "Colors", "Green", {
        "Colors", "Custom", "PlayerTear", 2
        }, 0, 1, 0.05, 2
    )

    addNumberSetting(menu, "Colors", "Blue", {
        "Colors", "Custom", "PlayerTear", 3
        }, 0, 1, 0.05, 2
    )

    mcmAddSpace(menu, "Colors")

    mcmAddTitle(menu, "Colors", "Friendly:", Config.Colors.Custom.FriendlyProjectile)

    addNumberSetting(menu, "Colors", "Red", {
        "Colors", "Custom", "FriendlyProjectile", 1
        }, 0, 1, 0.05, 2
    )

    addNumberSetting(menu, "Colors", "Green", {
        "Colors", "Custom", "FriendlyProjectile", 2
        }, 0, 1, 0.05, 2
    )

    addNumberSetting(menu, "Colors", "Blue", {
        "Colors", "Custom", "FriendlyProjectile", 3
        }, 0, 1, 0.05, 2
    )

    mcmAddSpace(menu, "Colors")

    mcmAddTitle(menu, "Colors", "Enemy:", Config.Colors.Custom.EnemyProjectile)

    addNumberSetting(menu, "Colors", "Red", {
        "Colors", "Custom", "EnemyProjectile", 1
        }, 0, 1, 0.05, 2
    )

    addNumberSetting(menu, "Colors", "Green", {
        "Colors", "Custom", "EnemyProjectile", 2
        }, 0, 1, 0.05, 2
    )

    addNumberSetting(menu, "Colors", "Blue", {
        "Colors", "Custom", "EnemyProjectile", 3
        }, 0, 1, 0.05, 2
    )

    -- Markers
    mcmAddTitle(menu, "Markers", "Circle")

    addVisibilitySetting(menu, "Markers", "Visibility", { "Marker", "Visibility" }, {
        "Controls when the ground ring is drawn.",
        "High/low arches use the height threshold to decide.",
    })

    addNumberSetting(menu, "Markers", "Alpha bottom", { "Marker", "AlphaBottom" }, 0, 1, 0.05, 2, {
        "Opacity at the bottom.",
    })

    addNumberSetting(menu, "Markers", "Alpha top", { "Marker", "AlphaTop" }, 0, 1, 0.05, 2, {
        "Opacity at the top.",
    })

    addNumberSetting(menu, "Markers", "Scale bottom", { "Marker", "ScaleBottom" }, 0.05, 2, 0.05, 2, {
        "Scale at the bottom.",
    })

    addNumberSetting(menu, "Markers", "Scale top", { "Marker", "ScaleTop" }, 0.05, 2, 0.05, 2, {
        "Scale at the top.",
    })

    addNumberSetting(menu, "Markers", "Bottom at height", { "Marker", "HeightForBottomValues" }, 0, 300, 2.5, 1, {
        "Height at which the circle's alpha/scale reaches its bottom values.",
    })

    addNumberSetting(menu, "Markers", "Top at height", { "Marker", "HeightForTopValues" }, 0, 300, 2.5, 1, {
        "Height at which the circle's alpha/scale reaches its bottom values",
    })

    mcmAddSpace(menu, "Markers")

    mcmAddTitle(menu, "Markers", "Center dot")

    addVisibilitySetting(menu, "Markers", "Visibility", { "CenterDot", "Visibility" }, {
        "Controls when the ground center dot is drawn.",
        "High/low arches use the height threshold to decide.",
    })

    addNumberSetting(menu, "Markers", "Alpha bottom", { "CenterDot", "AlphaBottom" }, 0, 1, 0.05, 2, {
        "Opacity at the bottom.",
    })

    addNumberSetting(menu, "Markers", "Alpha top", { "CenterDot", "AlphaTop" }, 0, 1, 0.05, 2, {
        "Opacity at tke top.",
    })

    addNumberSetting(menu, "Markers", "Scale bottom", { "CenterDot", "ScaleBottom" }, 0.05, 2, 0.05, 2, {
        "Scale at the bottom.",
    })

    addNumberSetting(menu, "Markers", "Scale top", { "CenterDot", "ScaleTop" }, 0.05, 2, 0.05, 2, {
        "Scale at the top.",
    })

    addNumberSetting(menu, "Markers", "Bottom at height", { "CenterDot", "HeightForBottomValues" }, 0, 300, 2.5, 1, {
        "Height at which the center dot's alpha/scale reach their bottom values.",
    })

    addNumberSetting(menu, "Markers", "Top at height", { "CenterDot", "HeightForTopValues" }, 0, 300, 2.5, 1, {
        "Height at which the center dot's alpha/scale reach their top values.",
    })

    -- Tether
    mcmAddTitle(menu, "Tether", "Tether")

    addVisibilitySetting(menu, "Tether", "Visibility", { "Tether", "Visibility" }, {
        "Controls when the vertical guide from the tear/projectile to the ground is drawn.",
        "High/low arches use the height threshold to decide.",
    })

    addNumberSetting(menu, "Tether", "Point spacing", { "Tether", "Step" }, 0.25, 40.00, 0.25, 2, {
        "Distance between points.",
    })

    addNumberSetting(menu, "Tether", "Point height", { "Tether", "Height" }, 0.05, 1.50, 0.05, 2, {
        "Height of each point.",
    })

    addNumberSetting(menu, "Tether", "Minimum tether length", { "Tether", "MinLength" }, 0, 300, 2.5, 1, {
        "Only tethers longer than this will be drawn.",
    })

    addNumberSetting(menu, "Tether", "Maximum tether length", { "Tether", "MaxLength" }, 0, 300, 2.5, 1, {
        "Only tethers longer than this will be drawn.",
        "0 means unlimited.",
    })

    addNumberSetting(menu, "Tether", "Alpha bottom", { "Tether", "AlphaBottom" }, 0, 1, 0.05, 2, {
        "Opacity at the bottom.",
    })

    addNumberSetting(menu, "Tether", "Alpha top", { "Tether", "AlphaTop" }, 0, 1, 0.05, 2, {
        "Opacity at the top.",
    })

    addNumberSetting(menu, "Tether", "Width bottom", { "Tether", "WidthBottom" }, 0, 5, 0.05, 2, {
        "Width at the bottom",
    })

    addNumberSetting(menu, "Tether", "Width top", { "Tether", "WidthTop" }, 0, 5.00, 0.05, 2, {
        "Width at the top.",
    })

    addNumberSetting(menu, "Tether", "Bottom at height", { "Tether", "HeightForBottomValues" }, 0, 300, 2.5, 1, {
        "Height at which the tether's alpha/width reach their bottom values.",
    })

    addNumberSetting(menu, "Tether", "Top at height", { "Tether", "HeightForTopValues" }, 0, 300, 2.5, 1, {
        "Height at which the tether's alpha/width reach their top values.",
    })

    -- Trail
    mcmAddTitle(menu, "Trail", "Trail")

    addVisibilitySetting(menu, "Trail", "Visibility", { "Trail", "Visibility" }, {
        "Controls when the short trail behind tears/projectiles is drawn.",
        "High/low arches use the height threshold to decide.",
    }, resetRuntimeData)

    addNumberSetting(menu, "Trail", "Length", { "Trail", "Length" }, 0, 20, 1, 0, {
        "Number of trail points at once.",
    }, resetRuntimeData)

    addNumberSetting(menu, "Trail", "Minimum distance", { "Trail", "MinDistance" }, 0, 20, 0.25, 2, {
        "Distance between trail points.",
    }, resetRuntimeData)

    addNumberSetting(menu, "Trail", "Center offset", { "Trail", "OffsetFromMarkerCenter" }, 0, 64, 1, 0, {
        "Delay the trail and move it back from the marker center.",
    })

    addNumberSetting(menu, "Trail", "Alpha bottom", { "Trail", "AlphaBottom" }, 0, 1, 0.05, 2, {
        "Opacity at the bottom.",
    })

    addNumberSetting(menu, "Trail", "Alpha top", { "Trail", "AlphaTop" }, 0, 1, 0.05, 2, {
        "Opacity at the top.",
    })

    addNumberSetting(menu, "Trail", "Scale bottom", { "Trail", "ScaleBottom" }, 0.05, 2, 0.05, 2, {
        "Scale at the bottom.",
    })

    addNumberSetting(menu, "Trail", "Scale top", { "Trail", "ScaleTop" }, 0.05, 2, 0.05, 2, {
        "Scale at the top.",
    })

    addNumberSetting(menu, "Trail", "Bottom at height", { "Trail", "HeightForBottomValues" }, 0, 300, 2.5, 1, {
        "Height at which the trail's alpha/scale reach their bottom values.",
    })

    addNumberSetting(menu, "Trail", "Top at height", { "Trail", "HeightForTopValues" }, 0, 300, 2.5, 1, {
        "Height at which the trail's alpha/scale reach their top values.",
    })

    -- Debug
    mcmAddTitle(menu, "Debug", "Debug Text")

    addYesNoSetting(menu, "Debug", "Enabled", { "General", "DebugText" }, {
        "Shows small debug counts in the top-left corner.",
    })

    mcmAddSpace(menu, "Debug")

    mcmAddTitle(menu, "Debug", "Projectile height")

    addVisibilitySetting(menu, "Debug", "Visibility", { "HeightText", "Visibility" }, {
        "Controls when the height number next to projectiles is shown.",
        "High/low arches use the height threshold to decide.",
    })

    addNumberSetting(menu, "Debug", "Minimum height", { "HeightText", "MinHeight" }, 0, 96, 1, 0, {
        "Height text is hidden below this current air height.",
    })

    addNumberSetting(menu, "Debug", "Decimals", { "HeightText", "Decimals" }, 0, 2, 1, 0, {
        "Number of decimal places shown in the height text.",
    })

    addNumberSetting(menu, "Debug", "Text scale", { "HeightText", "Scale" }, 0.25, 2, 0.05, 2, {
        "Scale of the height text.",
    })

    addNumberSetting(menu, "Debug", "Text alpha", { "HeightText", "Alpha" }, 0, 1, 0.05, 2, {
        "Opacity of the height text.",
    })

    addNumberSetting(menu, "Debug", "Offset X", { "HeightText", "OffsetX" }, -64, 64, 1, 0, {
        "Horizontal screen offset from the visible projectile position.",
    })

    addNumberSetting(menu, "Debug", "Offset Y", { "HeightText", "OffsetY" }, -64, 64, 1, 0, {
        "Vertical screen offset from the visible projectile position.",
    })

    addYesNoSetting(menu, "Debug", "Use PositionOffset", { "HeightText", "UsePositionOffset" }, {
        "Uses the projectile's visual PositionOffset when placing height text.",
    })

    mcmAddSpace(menu, "Debug")

    mcmAddTitle(menu, "Debug", "Sprites")

    addYesNoSetting(menu, "Debug", "Use sprites", { "Sprites", "Enabled" }, {
        "Uses Tear Indicator's soft sprite indicators.",
        "If disabled, text fallback glyphs are used.",
    })

    addYesNoSetting(menu, "Debug", "Fallback to text", { "Sprites", "FallbackToText" }, {
        "If sprite loading fails, draw text glyphs instead.",
    })

    mcmRegistered = true
    Isaac.DebugString(MOD_NAME .. ": Mod Config Menu registered")
end

-- ============================================================================
-- Callbacks
-- ============================================================================

function Indicator:OnPostUpdate()
    setupModConfigMenu()

    if not Config.General.Enabled then
        return
    end

    local entities = Isaac.GetRoomEntities()

    for _, entity in ipairs(entities) do
        local kind = classifyEntity(entity)

        if kind ~= nil and passesBaseFilters(entity, kind) then
            local state = getOrCreateEntityState(entity, kind)
            recordTrailPoint(entity, state)
        end
    end

    pruneEntityStates()
    updateIndicatorSlots()
end

function Indicator:OnPostRender()
    setupModConfigMenu()

    if not Config.General.Enabled then
        return
    end

    local tearCount = 0
    local projectileCount = 0
    local shownCount = 0
    local activeIndicatorCount = 0

    local entities = Isaac.GetRoomEntities()

    for _, entity in ipairs(entities) do
        local kind = classifyEntity(entity)

        if kind ~= nil then
            if kind == "tear" then
                tearCount = tearCount + 1
            else
                projectileCount = projectileCount + 1
            end

            if passesBaseFilters(entity, kind) then
                local key = getEntityKey(entity)
                local state = entityStates[key]

                if state == nil then
                    state = getOrCreateEntityState(entity, kind)
                end

                if state.IndicatorActive then
                    activeIndicatorCount = activeIndicatorCount + 1
                end

                if shouldRenderEntity(entity, kind, state) then
                    shownCount = shownCount + 1
                    renderEntityIndicator(entity, kind, state)
                end
            end
        end
    end

    if Config.General.DebugText then
        Isaac.RenderText(MOD_NAME .. " " .. VERSION, 8, 28, 0.3, 1, 1, 1)
        Isaac.RenderText(
            string.format(
                "tears=%d projectiles=%d shown=%d active=%d",
                tearCount,
                projectileCount,
                shownCount,
                activeIndicatorCount
            ),
            8,
            40,
            0.7,
            1,
            1,
            1
        )
    end
end

function Indicator:OnNewRoom()
    resetRuntimeData()
end

function Indicator:OnGameStarted()
    setupModConfigMenu()
    resetRuntimeData()
end

function Indicator:OnPreGameExit()
    saveConfig()
end

Indicator:AddCallback(ModCallbacks.MC_POST_UPDATE, Indicator.OnPostUpdate)
Indicator:AddCallback(ModCallbacks.MC_POST_RENDER, Indicator.OnPostRender)
Indicator:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, Indicator.OnNewRoom)
Indicator:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, Indicator.OnGameStarted)

if ModCallbacks.MC_PRE_GAME_EXIT ~= nil then
    Indicator:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, Indicator.OnPreGameExit)
end

setupModConfigMenu()

Isaac.DebugString(MOD_NAME .. " " .. VERSION .. " loaded")