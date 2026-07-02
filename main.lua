local MOD_NAME = "Tear Indicator"
local VERSION = "3.0.0"

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

    Sprites = {
        Enabled = true,
        FallbackToText = true,

        Anm2Path = "gfx/indicator/indicators.anm2",
        PngPath = "gfx/indicator/indicators.png",
    },

    Cleanup = {
        StaleFrames = 20,
    },

    -- Live preview drawn over an Indikator's Mod Config Menu tab.
    Preview = {
        Enabled = true,
    },

    -- Runtime-created indicator instances. Each entry is one Indikator tab: a
    -- Type plus its own settings for every type, so switching Type never loses
    -- another type's values. Seeded with one instance on first launch (see
    -- loadConfig). The renderer iterates this list.
    Indikators = {},
}

-- The Mode selector choices for an Indikator, in display/order.
local IndikatorTypes = { "Marker", "Tether", "Trail", "Number" }

-- The Class an Indikator targets, chosen at creation alongside Type. Projectiles
-- go through the full height-arc pipeline; Entities (enemies/familiars/player)
-- use a simpler, always-visible option set. Index into this list is stored as
-- inst.Class.
local IndikatorClasses = { "Projectile", "Entity" }

-- Title tint per Class, so an Indikator tab reads at a glance as blue (Projectile)
-- or orange (Entity). Indexed by inst.Class; passed to mcmAddTitle.
local INDIKATOR_CLASS_COLORS = {
    { 0.35, 0.60, 1.00 }, -- Projectile: blue
    { 1.00, 0.60, 0.20 }, -- Entity: orange
}

-- Minimum projectile damage (EntityProjectile.Damage) counted as "a full heart"
-- for the Projectile-class Full-heart-damage filter. 1.0 is a standard enemy shot
-- (one red heart on Normal); tune here if needed.
local FULL_HEART_DAMAGE = 1

-- ============================================================================
-- Sprite catalog
--
-- Each entry is one named sprite an Indikator can use. A sprite is one 32px
-- cell of the spritesheet, exposed through one anm2 animation. The picker on a
-- Marker/Tether/Trail tab lists the catalog entries whose Types include that
-- tab's type, and the renderer draws the chosen entry's Anim.
--
--   Name     shown in the picker; unique; also the value stored in the config
--   Anim     anm2 animation name = one sheet cell (see indicators.anm2)
--   Types    which Indikator types may select it ("Marker"/"Tether"/"Trail")
--   Fallback text glyph drawn when sprites are unavailable
--
-- To ADD a hand-drawn sprite:
--   1. Draw a 32x32 cell into resources/gfx/indicator/indicators.png at grid
--      position (col, row); widen/heighten the sheet as needed.
--   2. Add an <Animation Name="..."> to indicators.anm2 whose LayerAnimation
--      frame uses XCrop = col*32, YCrop = row*32, Width/Height = 32.
--   3. Add an entry below with that Anim name and the Types it suits.
-- This list, the anm2 animations, and the png cells are kept in sync by hand.
-- ============================================================================
-- Order matters: the first entry available to a type is that type's default
-- (see makeIndikatorData), so each type's original sprite is listed first to
-- preserve the out-of-box look. "Solid" is shared, so it comes last.
local SpriteCatalog = {
    { Name = "Ring",  Anim = "Marker", Types = { "Marker" },                     Fallback = "O" },
    { Name = "Dot",   Anim = "Trail",  Types = { "Marker", "Trail" },            Fallback = "." },
    { Name = "Bead",  Anim = "Tether", Types = { "Tether" },                     Fallback = "I" },
    { Name = "Solid", Anim = "Center", Types = { "Marker", "Trail", "Tether" },  Fallback = "+" },
}

-- Derived lookups, built once from the catalog above.
--   SymbolsByType[type] -> ordered list of entries available to that type
--   SymbolByName[name]  -> entry, for resolving a stored Symbol at render time
local SymbolsByType = {}
local SymbolByName = {}

for _, sym in ipairs(SpriteCatalog) do
    SymbolByName[sym.Name] = sym

    for _, t in ipairs(sym.Types) do
        SymbolsByType[t] = SymbolsByType[t] or {}
        table.insert(SymbolsByType[t], sym)
    end
end

-- The default symbol name for a type (first one declared for it).
local function defaultSymbolName(typeName)
    local list = SymbolsByType[typeName]
    return list and list[1] and list[1].Name or nil
end

-- Index of a symbol name within a type's available list (1 if not found).
local function symbolIndexInList(list, name)
    for i = 1, #list do
        if list[i].Name == name then
            return i
        end
    end

    return 1
end

-- Fresh per-type defaults for one Indikator. Values mirror the old global
-- Marker/Tether/Trail/HeightText defaults plus the shared Targets table (source
-- toggles + class filters) and cap each type now carries.
local function makeIndikatorData()
    return {
        Type = 1, -- index into IndikatorTypes
        Class = 1, -- index into IndikatorClasses (Projectile / Entity)

        Marker = {
            Visibility = "Only for high arches",
            HeightThreshold = 45,
            MarkFromStartToEnd = true,
            Symbol = defaultSymbolName("Marker"),
            AlphaBottom = 0.85,
            AlphaTop = 0.40,
            ScaleBottom = 0.55,
            ScaleTop = 0.20,
            HeightForBottomValues = 25,
            HeightForTopValues = 200,
            -- Which sources this Indikator draws for. Meaning depends on the
            -- instance's Class: for Projectile, Player/Enemies/Familiars select
            -- player tears / enemy shots / familiar tears; for Entity they select
            -- the player / hostile NPCs / familiars. Flying (Entity) and
            -- FullHeartDamage (Projectile) are class-specific refinement filters.
            Targets = {
                Player = true,
                Enemies = true,
                Familiars = false,
                Flying = false,
                FullHeartDamage = false,
            },
            MaxActiveIndicators = 80,
        },

        Tether = {
            Visibility = "Only for high arches",
            HeightThreshold = 45,
            MarkFromStartToEnd = true,
            Symbol = defaultSymbolName("Tether"),
            Step = 5.75,
            Height = 0.40,
            MinLength = 0,
            MaxLength = 200,
            AlphaBottom = 1.00,
            AlphaTop = 0.00,
            WidthBottom = 0.30,
            WidthTop = 0.30,
            HeightForBottomValues = 40,
            HeightForTopValues = 200,
            -- Which sources this Indikator draws for. Meaning depends on the
            -- instance's Class: for Projectile, Player/Enemies/Familiars select
            -- player tears / enemy shots / familiar tears; for Entity they select
            -- the player / hostile NPCs / familiars. Flying (Entity) and
            -- FullHeartDamage (Projectile) are class-specific refinement filters.
            Targets = {
                Player = true,
                Enemies = true,
                Familiars = false,
                Flying = false,
                FullHeartDamage = false,
            },
            MaxActiveIndicators = 80,
        },

        Trail = {
            Visibility = "Always",
            HeightThreshold = 45,
            MarkFromStartToEnd = true,
            Symbol = defaultSymbolName("Trail"),
            PointCount = 5,
            MinDistance = 10.00,
            OffsetFromMarkerCenter = 0,
            AlphaBottom = 1.00,
            AlphaTop = 1.00,
            ScaleBottom = 0.15,
            ScaleTop = 0.15,
            HeightForBottomValues = 25,
            HeightForTopValues = 200,
            -- Which sources this Indikator draws for. Meaning depends on the
            -- instance's Class: for Projectile, Player/Enemies/Familiars select
            -- player tears / enemy shots / familiar tears; for Entity they select
            -- the player / hostile NPCs / familiars. Flying (Entity) and
            -- FullHeartDamage (Projectile) are class-specific refinement filters.
            Targets = {
                Player = true,
                Enemies = true,
                Familiars = false,
                Flying = false,
                FullHeartDamage = false,
            },
            MaxActiveIndicators = 80,
        },

        Number = {
            Visibility = "Disabled",
            HeightThreshold = 45,
            MarkFromStartToEnd = true,
            MinHeight = 0,
            Decimals = 0,
            Scale = 0.70,
            Alpha = 0.90,
            OffsetX = 8,
            OffsetY = -6,
            UsePositionOffset = true,
            -- Which sources this Indikator draws for. Meaning depends on the
            -- instance's Class: for Projectile, Player/Enemies/Familiars select
            -- player tears / enemy shots / familiar tears; for Entity they select
            -- the player / hostile NPCs / familiars. Flying (Entity) and
            -- FullHeartDamage (Projectile) are class-specific refinement filters.
            Targets = {
                Player = true,
                Enemies = true,
                Familiars = false,
                Flying = false,
                FullHeartDamage = false,
            },
            MaxActiveIndicators = 80,
        },
    }
end

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
        -- Fresh install: start with a single Indikator to configure.
        Config.Indikators = { makeIndikatorData() }
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

    -- mergeConfig only keeps keys present in the defaults, so the dynamic
    -- Indikators array is dropped. Restore it here, normalizing each instance
    -- against a fresh template so missing fields are filled in.
    Config.Indikators = {}
    if type(savedConfig) == "table" and type(savedConfig.Indikators) == "table" then
        for _, instance in ipairs(savedConfig.Indikators) do
            if type(instance) == "table" then
                table.insert(Config.Indikators, mergeConfig(makeIndikatorData(), instance))
            end
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

-- Derived from the sprite catalog: Anim -> fallback text glyph, plus the set of
-- unique anims to preload (one per distinct sheet cell in use).
local FallbackGlyphs = {}
local SpriteAnims = {}
do
    local seen = {}
    for _, sym in ipairs(SpriteCatalog) do
        FallbackGlyphs[sym.Anim] = sym.Fallback
        if not seen[sym.Anim] then
            seen[sym.Anim] = true
            table.insert(SpriteAnims, sym.Anim)
        end
    end
end

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
        indicatorSprites = {}

        for _, anim in ipairs(SpriteAnims) do
            local sprite = makeIndicatorSprite(anim)
            indicatorSprites[anim] = sprite

            if sprite == nil or not sprite:IsLoaded() then
                return false
            end
        end

        return true
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

-- Familiars fire ENTITY_TEAR (spawner = familiar); we treat those as a
-- projectile-class source routed to the Familiars target.
local function isFamiliarTear(entity)
    return entity.SpawnerType == EntityType.ENTITY_FAMILIAR
end

-- The projectile-class source ("Player" / "Familiars" / "Enemies") an airborne
-- tear or projectile belongs to.
local function projectileSource(entity)
    if entity.Type == EntityType.ENTITY_TEAR then
        if isFamiliarTear(entity) then
            return "Familiars"
        end

        return "Player"
    end

    -- ENTITY_PROJECTILE
    if entity.SpawnerType == EntityType.ENTITY_PLAYER then
        return "Player"
    end

    if entity.SpawnerType == EntityType.ENTITY_FAMILIAR
        or entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) then
        return "Familiars"
    end

    return "Enemies"
end

-- Classifies a room entity into the model the Indikators target, or nil to
-- ignore it (pickups, effects, ...). Returns a descriptor whose fields the match
-- predicate reads (the same fields are copied onto the tracked entity state).
-- Class matches the IndikatorClasses strings so it can be compared directly:
--   Class          "Projectile" | "Entity"
--   Source         "Player" | "Enemies" | "Familiars"
--   DamageToPlayer Projectile-class: the shot's damage to the player (0 unless enemy)
--   IsFlying       Entity-class: whether the entity is flying
local function classifyEntity(entity)
    local etype = entity.Type

    if etype == EntityType.ENTITY_TEAR
        or (EntityType.ENTITY_PROJECTILE ~= nil and etype == EntityType.ENTITY_PROJECTILE) then
        local source = projectileSource(entity)
        local damageToPlayer = 0

        if source == "Enemies" and etype == EntityType.ENTITY_PROJECTILE then
            local projectile = entity:ToProjectile()
            if projectile ~= nil and projectile.Damage ~= nil then
                damageToPlayer = projectile.Damage
            end
        end

        return {
            Class = "Projectile",
            Source = source,
            DamageToPlayer = damageToPlayer,
        }
    end

    if etype == EntityType.ENTITY_PLAYER then
        return { Class = "Entity", Source = "Player", IsFlying = entity:IsFlying() }
    end

    if etype == EntityType.ENTITY_FAMILIAR then
        return { Class = "Entity", Source = "Familiars", IsFlying = entity:IsFlying() }
    end

    if entity:IsEnemy() then
        return { Class = "Entity", Source = "Enemies", IsFlying = entity:IsFlying() }
    end

    return nil
end

-- The preset color for a source, shared by both classes: player-blue for the
-- player / their tears, friendly for familiars, enemy for hostiles.
local function sourceColor(source)
    local preset = getColorPreset()

    if source == "Player" then
        return preset.PlayerTear
    end

    if source == "Familiars" then
        return preset.FriendlyProjectile
    end

    return preset.EnemyProjectile
end

local function passesBaseEntityChecks(entity)
    if entity == nil or not entity:Exists() then
        return false
    end

    return entity.Visible
end

-- The per-type settings subtable an Indikator instance is currently using.
local function indikatorStore(inst)
    return inst[IndikatorTypes[inst.Type]]
end

-- Whether an Indikator draws for a given classified descriptor (a live
-- classifyEntity result or a tracked entity state, which share the same fields).
-- Class must match, at least one enabled source must match, and any class filter
-- (Entity: Flying, Projectile: FullHeartDamage) must pass.
local function indikatorMatches(inst, descriptor)
    if IndikatorClasses[inst.Class] ~= descriptor.Class then
        return false
    end

    local t = indikatorStore(inst).Targets

    local source = (t.Player and descriptor.Source == "Player")
        or (t.Enemies and descriptor.Source == "Enemies")
        or (t.Familiars and descriptor.Source == "Familiars")

    if not source then
        return false
    end

    if descriptor.Class == "Entity" and t.Flying and not descriptor.IsFlying then
        return false
    end

    if descriptor.Class == "Projectile" and t.FullHeartDamage
        and (descriptor.DamageToPlayer or 0) < FULL_HEART_DAMAGE then
        return false
    end

    return true
end

-- True if at least one Indikator targets this descriptor, i.e. the entity is
-- worth tracking at all.
local function entityWantedByAnyIndikator(descriptor)
    for _, inst in ipairs(Config.Indikators) do
        if indikatorMatches(inst, descriptor) then
            return true
        end
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

-- ============================================================================
-- Runtime tracking
-- ============================================================================

local entityStates = {}

resetRuntimeData = function()
    entityStates = {}
end

local function getOrCreateEntityState(entity, info)
    local key = getEntityKey(entity)
    local frame = game:GetFrameCount()

    local state = entityStates[key]

    if state == nil then
        state = {
            Key = key,

            -- Classification fields (see classifyEntity); indikatorMatches reads
            -- these directly off the state.
            Class = info.Class,
            Source = info.Source,
            DamageToPlayer = info.DamageToPlayer,
            IsFlying = info.IsFlying,

            SpawnFrame = frame,
            LastSeenFrame = frame,

            Position = Vector(entity.Position.X, entity.Position.Y),

            -- Highest lifetime values; qualification is derived per Indikator
            -- from these plus that Indikator's threshold/peak-hint setting.
            MaxCurrentHeight = 0,
            MaxRawHeight = 0,

            -- Per-Indikator runtime, keyed by the instance table:
            --   Indi[inst]   = { Qualified, Active, SlotFrame }
            --   Trails[inst] = { Points, LastSampleFrame }
            Indi = {},
            Trails = {},
        }

        entityStates[key] = state
    end

    state.Class = info.Class
    state.Source = info.Source
    state.DamageToPlayer = info.DamageToPlayer
    state.IsFlying = info.IsFlying
    state.LastSeenFrame = frame
    state.Position = Vector(entity.Position.X, entity.Position.Y)

    local cur = getCurrentAirHeight(entity)
    local raw = math.abs(getRawHeight(entity))

    if cur > state.MaxCurrentHeight then
        state.MaxCurrentHeight = cur
    end

    if raw > state.MaxRawHeight then
        state.MaxRawHeight = raw
    end

    return state
end

-- Fallback point count if an instance somehow lacks the field.
local TRAIL_POINT_LIMIT = 5

-- Samples a position into a Trail-type Indikator's own buffer for one entity.
-- Each Trail Indikator keeps its own buffer (keyed by the instance) so they can
-- use different MinDistance spacing and point counts.
local function sampleTrail(state, inst, store)
    local buf = state.Trails[inst]

    if buf == nil then
        buf = { Points = {}, LastSampleFrame = -999999 }
        state.Trails[inst] = buf
    end

    local points = buf.Points
    local pos = state.Position
    local shouldSample = false

    if #points == 0 then
        shouldSample = true
    else
        local last = points[#points]
        local dx = pos.X - last.X
        local dy = pos.Y - last.Y
        local minDistance = store.MinDistance or 0

        if (dx * dx + dy * dy) >= minDistance * minDistance then
            shouldSample = true
        end
    end

    if not shouldSample then
        return
    end

    table.insert(points, Vector(pos.X, pos.Y))
    buf.LastSampleFrame = game:GetFrameCount()

    local limit = math.floor(store.PointCount or TRAIL_POINT_LIMIT)
    if limit < 1 then
        limit = 1
    end

    while #points > limit do
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

-- Whether an entity should draw for an Indikator given its visibility mode and
-- whether it is height-qualified (a "high arch"). This is the full visibility
-- decision; the Max-active cap is then applied on top of it.
local function visibilityWantsRender(visibility, qualified)
    if visibility == "Disabled" then
        return false
    end

    if visibility == "Only for high arches" then
        return qualified
    end

    if visibility == "Only for low arches" then
        return not qualified
    end

    -- "Always" (and any unexpected value) renders regardless of height.
    return true
end

-- Stable slot allocation for one Indikator: keep already-active entities that
-- still want to render, then fill any spare slots with the oldest such
-- entities. Operates on each entity's per-instance slot (state.Indi[inst]),
-- whose WantsRender flag must already be set for this frame. This is what makes
-- the Max-active cap bound the rendered count in every visibility mode.
local function allocateIndikatorSlots(inst, maxActive, frame)
    if maxActive <= 0 then
        for _, state in pairs(entityStates) do
            local slot = state.Indi[inst]
            if slot ~= nil then
                if slot.WantsRender then
                    if not slot.Active then
                        slot.SlotFrame = frame
                    end
                    slot.Active = true
                else
                    slot.Active = false
                    slot.SlotFrame = nil
                end
            end
        end

        return
    end

    local active = {}

    for _, state in pairs(entityStates) do
        local slot = state.Indi[inst]
        if slot ~= nil then
            if slot.Active and slot.WantsRender then
                table.insert(active, state)
            else
                slot.Active = false
                slot.SlotFrame = nil
            end
        end
    end

    table.sort(active, function(a, b)
        local aSlot = a.Indi[inst].SlotFrame or a.SpawnFrame
        local bSlot = b.Indi[inst].SlotFrame or b.SpawnFrame

        if aSlot == bSlot then
            return a.Key < b.Key
        end

        return aSlot < bSlot
    end)

    for i = maxActive + 1, #active do
        active[i].Indi[inst].Active = false
        active[i].Indi[inst].SlotFrame = nil
    end

    local activeCount = math.min(#active, maxActive)

    if activeCount >= maxActive then
        return
    end

    local candidates = {}

    for _, state in pairs(entityStates) do
        local slot = state.Indi[inst]
        if slot ~= nil and slot.WantsRender and not slot.Active then
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

        state.Indi[inst].Active = true
        state.Indi[inst].SlotFrame = frame
        activeCount = activeCount + 1
    end
end

-- For every Indikator: derive each tracked entity's qualification from that
-- Indikator's own threshold/peak-hint, allocate slots, and (for Trail types)
-- sample trail points.
local function updateIndikatorRuntime()
    local frame = game:GetFrameCount()

    for _, inst in ipairs(Config.Indikators) do
        local store = indikatorStore(inst)

        -- Entity-class Indikators don't expose the height-arc gating, so they are
        -- always-on: no threshold and Visibility forced to "Always". The Max-active
        -- cap still bounds how many render.
        local isEntity = IndikatorClasses[inst.Class] == "Entity"
        local threshold = isEntity and 0 or (store.HeightThreshold or 0)
        local visibility = isEntity and "Always" or store.Visibility

        local peakHint = store.MarkFromStartToEnd
        local maxActive = math.floor(store.MaxActiveIndicators or 0)
        local isTrail = inst.Type == 3
        local trailEnabled = isTrail and visibility ~= "Disabled"

        for _, state in pairs(entityStates) do
            if indikatorMatches(inst, state) then
                local slot = state.Indi[inst]
                if slot == nil then
                    slot = { WantsRender = false, Active = false, SlotFrame = nil }
                    state.Indi[inst] = slot
                end

                local highest = state.MaxCurrentHeight
                if peakHint and state.MaxRawHeight > highest then
                    highest = state.MaxRawHeight
                end

                local qualified = threshold <= 0 or highest >= threshold
                slot.WantsRender = visibilityWantsRender(visibility, qualified)

                if trailEnabled then
                    sampleTrail(state, inst, store)
                end
            else
                local slot = state.Indi[inst]
                if slot ~= nil then
                    slot.WantsRender = false
                    slot.Active = false
                    slot.SlotFrame = nil
                end
            end
        end

        allocateIndikatorSlots(inst, maxActive, frame)
    end
end

-- ============================================================================
-- Indicator rendering
-- ============================================================================

local function getHeightLerpValue(currentHeight, HeightForBottomValues, HeightForTopValues)
    HeightForBottomValues = HeightForBottomValues or 0

    -- If the range is empty or inverted, snap straight to the max values.
    if HeightForTopValues == nil or HeightForTopValues <= HeightForBottomValues then
        return 1
    end

    local span = HeightForTopValues - HeightForBottomValues
    return clamp(((currentHeight or 0) - HeightForBottomValues) / span, 0, 1)
end

local function getTrailPointWithCenterOffset(point, centerPos, offset)
    offset = offset or 0

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

-- Resolves an Indikator's stored Symbol name to the anm2 animation to draw.
-- Falls back to the type's first available symbol if the stored one is missing
-- or no longer valid for this type. drawIndicatorSprite maps the anim back to a
-- text glyph (via FallbackGlyphs) when sprites are unavailable.
local function resolveSymbolAnim(symbolName, typeName)
    local sym = SymbolByName[symbolName]

    if sym ~= nil then
        for _, t in ipairs(sym.Types) do
            if t == typeName then
                return sym.Anim
            end
        end
    end

    local list = SymbolsByType[typeName]
    local first = list and list[1] or nil
    return first and first.Anim or typeName
end

-- Screen-space core: draws a trail from an array of screen points (oldest
-- first). The last point is the live position and is not drawn, matching the
-- in-game look. Shared by the live renderer and the menu preview.
local function renderTrailCore(store, rgb, screenPoints, currentHeight)
    local count = #screenPoints

    if count <= 1 then
        return
    end

    local t = getHeightLerpValue(currentHeight, store.HeightForBottomValues, store.HeightForTopValues)
    local alpha = lerp(store.AlphaBottom, store.AlphaTop, t)
    local scale = lerp(store.ScaleBottom, store.ScaleTop, t)

    local drawableCount = count - 1
    local anim = resolveSymbolAnim(store.Symbol, "Trail")

    for i = 1, drawableCount do
        local f = i / drawableCount

        drawIndicatorSprite(
            anim,
            screenPoints[i],
            scale * f,
            nil,
            rgb,
            alpha * f,
            0.90 * f
        )
    end
end

local function renderTrailIndikator(entity, store, buf, rgb, currentHeight)
    if buf == nil then
        return
    end

    local points = buf.Points
    if #points <= 1 then
        return
    end

    local offset = store.OffsetFromMarkerCenter or 0
    local centerPos = entity.Position

    local screenPoints = {}
    for i = 1, #points do
        screenPoints[i] = worldToScreen(getTrailPointWithCenterOffset(points[i], centerPos, offset))
    end

    renderTrailCore(store, rgb, screenPoints, currentHeight)
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

-- The tether's end offsets and position-offset usage are no longer exposed in
-- the new Tether type, so they use the previous defaults.
local TETHER_TOP_Y_OFFSET = 6
local TETHER_BOTTOM_Y_OFFSET = 0
local TETHER_USE_POSITION_OFFSET = true

-- Screen-space core: draws the dotted tether between a ground point and the
-- projectile's on-screen position. Shared by the live renderer and the preview.
local function renderTetherCore(store, rgb, groundScreenPos, visualScreenPos, currentHeight)
    local t = getHeightLerpValue(currentHeight, store.HeightForBottomValues, store.HeightForTopValues)
    local alpha = lerp(store.AlphaBottom, store.AlphaTop, t)
    local width = lerp(store.WidthBottom, store.WidthTop, t)

    local topY = visualScreenPos.Y + TETHER_TOP_Y_OFFSET
    local bottomY = groundScreenPos.Y + TETHER_BOTTOM_Y_OFFSET
    local length = bottomY - topY

    if length < (store.MinLength or 0) then
        return
    end

    local maxLength = store.MaxLength or 0
    if maxLength > 0 and length > maxLength then
        topY = bottomY - maxLength
    end

    local x = groundScreenPos.X
    local y = topY

    local step = store.Step or 4
    if step <= 0 then
        step = 4
    end

    local tetherScaleY = store.Height
    local anim = resolveSymbolAnim(store.Symbol, "Tether")

    while y <= bottomY do
        drawIndicatorSprite(
            anim,
            Vector(x, y),
            width,
            tetherScaleY,
            rgb,
            alpha,
            0.7
        )

        y = y + step
    end
end

local function renderTetherIndikator(entity, store, rgb, groundScreenPos, currentHeight)
    local visualScreenPos = getProjectileVisualScreenPos(
        entity,
        groundScreenPos,
        TETHER_USE_POSITION_OFFSET
    )

    renderTetherCore(store, rgb, groundScreenPos, visualScreenPos, currentHeight)
end

local function renderMarkerIndikator(store, rgb, groundScreenPos, currentHeight)
    local t = getHeightLerpValue(currentHeight, store.HeightForBottomValues, store.HeightForTopValues)
    local alpha = lerp(store.AlphaBottom, store.AlphaTop, t)
    local scale = lerp(store.ScaleBottom, store.ScaleTop, t)
    local anim = resolveSymbolAnim(store.Symbol, "Marker")

    drawIndicatorSprite(
        anim,
        groundScreenPos,
        scale,
        nil,
        rgb,
        alpha,
        1.00
    )
end

-- Screen-space core: draws the height number at a given screen position. Shared
-- by the live renderer and the preview.
local function renderNumberCore(store, rgb, screenPos, heightValue)
    if heightValue < (store.MinHeight or 0) then
        return
    end

    local decimals = clamp(math.floor((store.Decimals or 0) + 0.5), 0, 2)
    local text = formatNumber(heightValue, decimals)
    local scale = store.Scale or 0.7
    local alpha = store.Alpha or 0.9

    local x = screenPos.X + (store.OffsetX or 0)
    local y = screenPos.Y + (store.OffsetY or 0)

    -- Small shadow for readability.
    renderText(text, x + 1, y + 1, scale, scale, 0, 0, 0, alpha * 0.75)
    renderText(text, x, y, scale, scale, rgb[1], rgb[2], rgb[3], alpha)
end

local function renderNumberIndikator(entity, store, rgb, groundScreenPos)
    local height = getCurrentAirHeight(entity)

    local visualScreenPos = getProjectileVisualScreenPos(
        entity,
        groundScreenPos,
        store.UsePositionOffset
    )

    renderNumberCore(store, rgb, visualScreenPos, height)
end

-- Draws one Indikator for one entity. The decision to draw (visibility mode +
-- Max-active cap) was already made in updateIndikatorRuntime, so the caller only
-- invokes this for an active slot. `state` may be nil only for trail buffers.
local function renderIndikator(inst, store, entity, state, rgb, groundScreenPos, currentHeight)
    local kind = inst.Type

    if kind == 1 then
        renderMarkerIndikator(store, rgb, groundScreenPos, currentHeight)
    elseif kind == 2 then
        renderTetherIndikator(entity, store, rgb, groundScreenPos, currentHeight)
    elseif kind == 3 then
        local buf = state ~= nil and state.Trails[inst] or nil
        renderTrailIndikator(entity, store, buf, rgb, currentHeight)
    else
        renderNumberIndikator(entity, store, rgb, groundScreenPos)
    end
end

-- ============================================================================
-- Mod Config Menu - Impure support
-- ============================================================================

local mcmRegistered = false

-- Set by dynamic-tab actions to request a deferred full rebuild of the menu.
local pendingMenuRebuild = false

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

            -- DefaultConfig has no Indikators, so reseed the starting one.
            Config.Indikators = { makeIndikatorData() }

            saveConfig()
            resetRuntimeData()

            -- Sprites may have changed paths/settings.
            indicatorSprites = nil
            spriteLoadAttempted = false
            spritesAvailable = false

            -- Indikator tabs changed, so rebuild the menu to match.
            pendingMenuRebuild = true
        end,

        Info = {
            "Resets all settings to their defaults.",
        },
    })
end

-- ----------------------------------------------------------------------------
-- Dynamic Indikator tabs
--
-- Each Indikator instance is one tab. Its Type (Marker/Tether/Trail/Number) is
-- picked on the Create tab at creation time, and the options shown depend on
-- that Type. MCM offers no way to remove a single subcategory, so adding and
-- removing tabs is done by rebuilding the whole mod category from this data
-- model. The rebuild is deferred (via pendingMenuRebuild) to the update phase
-- so we never tear down MCM's structures while it is mid-render.
-- ----------------------------------------------------------------------------

-- The Type and Class a freshly created Indikator will use, chosen on the Create
-- tab. Both are transient UI selections, not part of the saved Config.
local newIndikatorType = 1
local newIndikatorClass = 1

-- Creates a new tab with the Type and Class currently chosen on the Create tab.
-- Appending (rather than inserting elsewhere) is deliberate: the new tab takes
-- the subcategory slot the Create tab held, so the rebuild lands the cursor on it
-- (see buildIndikatorTabs).
local function createIndikator()
    local data = makeIndikatorData()
    data.Type = newIndikatorType
    data.Class = newIndikatorClass
    table.insert(Config.Indikators, data)
    saveConfig()
    pendingMenuRebuild = true
end

-- Instances are identified by table identity, so removing one renumbers the
-- rest automatically.
local function deleteIndikator(instance)
    for i, other in ipairs(Config.Indikators) do
        if other == instance then
            table.remove(Config.Indikators, i)
            break
        end
    end

    saveConfig()
    pendingMenuRebuild = true
end

-- An action "button". Selecting it (confirm key, or right) opens a confirmation
-- popup; the action only runs when the popup itself is confirmed. Using a popup
-- instead of a boolean avoids the toggle-on-left/right behaviour that made the
-- old buttons fire from a stray arrow press.
local function addActionButton(menu, tabName, label, popupLines, action, confirm)
    menu.AddSetting(MOD_NAME, tabName, {
        Type = menu.OptionType.TEXT,

        Display = function()
            return label
        end,

        -- MCM treats each table entry as its own line (it only honours $newline
        -- inside a string, not "\n"), so the prompt is built as a line list.
        Popup = confirm and function()
            return popupLines
        end or nil,

        PopupGfx = confirm and (menu.PopupGfx and menu.PopupGfx.WIDE_SMALL or nil) or nil,
        PopupWidth = confirm and 280 or nil,

        OnSelect = action,
    })
end

-- Per-instance option helpers. `store` is the instance's per-type subtable and
-- `field` the key within it, so every Indikator edits its own values.
local function indikatorNumber(menu, tab, store, field, label, minValue, maxValue, step, decimals, info)
    local settings = {
        Type = menu.OptionType.NUMBER,
        Minimum = minValue,
        Maximum = maxValue,
        ModifyBy = step or 1,

        CurrentSetting = function()
            return store[field]
        end,

        Display = function()
            return label .. ": " .. tostring(roundNumber(store[field] or 0, decimals or 0))
        end,

        OnChange = function(value)
            value = clamp(value or minValue, minValue, maxValue)
            if decimals ~= nil and decimals > 0 then
                value = roundNumber(value, decimals)
            else
                value = math.floor(value + 0.5)
            end
            store[field] = value
            saveConfig()
        end,

        Info = info,
    }

    -- Tag bottom/top-paired fields (AlphaBottom, ScaleTop, HeightForTopValues, ...)
    -- so the settings preview can hold that end while the option is focused. MCM
    -- preserves unknown fields, so we read this back via MCM.CurrentOption.
    if field:find("Bottom", 1, true) then
        settings.PreviewHeight = "bottom"
    elseif field:find("Top", 1, true) then
        settings.PreviewHeight = "top"
    elseif field == "MinLength" then
        settings.PreviewHeight = "minlen"
    elseif field == "MaxLength" then
        settings.PreviewHeight = "maxlen"
    elseif field == "HeightThreshold" then
        settings.PreviewHeight = "threshold"
    end

    menu.AddSetting(MOD_NAME, tab, settings)
end

local function indikatorToggle(menu, tab, store, field, label, info)
    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.BOOLEAN,

        CurrentSetting = function()
            return store[field]
        end,

        Display = function()
            return label .. ": " .. getYesNoText(store[field])
        end,

        OnChange = function(value)
            store[field] = value
            saveConfig()
        end,

        Info = info,
    })
end

local function indikatorVisibility(menu, tab, store, field, label, info)
    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.NUMBER,
        Minimum = 1,
        Maximum = #VisibilityOptions,
        ModifyBy = 1,

        -- Visibility keys off the height threshold (high/low arch), so focusing it
        -- highlights the "Thr" line in the preview and snaps the tear to it.
        PreviewHeight = "threshold",

        CurrentSetting = function()
            return visibilityIndex(store[field])
        end,

        Display = function()
            return label .. ": " .. VisibilityOptions[visibilityIndex(store[field])]
        end,

        OnChange = function(value)
            local index = clamp(math.floor((value or 1) + 0.5), 1, #VisibilityOptions)
            store[field] = VisibilityOptions[index]
            saveConfig()
        end,

        Info = info,
    })
end

-- Symbol picker: cycles the named sprites the catalog makes available to this
-- Indikator's type. Stores the chosen symbol's Name (a stable key); the renderer
-- resolves it back to an anm2 animation via resolveSymbolAnim.
local function indikatorSymbol(menu, tab, store, typeName)
    local list = SymbolsByType[typeName] or {}

    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.NUMBER,
        Minimum = 1,
        Maximum = math.max(#list, 1),
        ModifyBy = 1,

        CurrentSetting = function()
            return symbolIndexInList(list, store.Symbol)
        end,

        Display = function()
            local sym = list[symbolIndexInList(list, store.Symbol)]
            return "Symbol: " .. (sym and sym.Name or "-")
        end,

        OnChange = function(value)
            if #list == 0 then
                return
            end

            local index = clamp(math.floor((value or 1) + 0.5), 1, #list)
            store.Symbol = list[index].Name
            saveConfig()
        end,

        Info = {
            "Which sprite this indicator draws.",
        },
    })
end

-- A NUMBER option that writes one shown value to two fields at once. Entity tabs
-- use it to drive a *Bottom/*Top pair from a single control, collapsing the
-- height-lerp to a constant (entities have no arc to interpolate over).
local function indikatorPairedNumber(menu, tab, store, fieldA, fieldB, label, minValue, maxValue, step, decimals, info)
    menu.AddSetting(MOD_NAME, tab, {
        Type = menu.OptionType.NUMBER,
        Minimum = minValue,
        Maximum = maxValue,
        ModifyBy = step or 1,

        CurrentSetting = function()
            return store[fieldA]
        end,

        Display = function()
            return label .. ": " .. tostring(roundNumber(store[fieldA] or 0, decimals or 0))
        end,

        OnChange = function(value)
            value = clamp(value or minValue, minValue, maxValue)
            if decimals ~= nil and decimals > 0 then
                value = roundNumber(value, decimals)
            else
                value = math.floor(value + 0.5)
            end
            store[fieldA] = value
            store[fieldB] = value
            saveConfig()
        end,

        Info = info,
    })
end

-- The "Targets" section every Indikator carries: source toggles (Player/Enemies/
-- Familiars), the class-specific refinement filter (Entity: Flying, Projectile:
-- Full heart damage), and the render cap. `class` is the instance's fixed class
-- string ("Projectile"/"Entity"); `color` tints the section title.
local function indikatorTargets(menu, tab, store, class, color)
    mcmAddTitle(menu, tab, "Targets", color)

    local targets = store.Targets

    if class == "Entity" then
        indikatorToggle(menu, tab, targets, "Player", "Player", {
            "Show this indicator for the player.",
        })
        indikatorToggle(menu, tab, targets, "Enemies", "Enemies", {
            "Show this indicator for hostile enemies.",
        })
        indikatorToggle(menu, tab, targets, "Familiars", "Familiars", {
            "Show this indicator for familiars.",
        })
        indikatorToggle(menu, tab, targets, "Flying", "Flying only", {
            "Restrict the sources above to flying entities only.",
        })
    else
        indikatorToggle(menu, tab, targets, "Player", "Player", {
            "Show this indicator for the player's tears.",
        })
        indikatorToggle(menu, tab, targets, "Enemies", "Enemies", {
            "Show this indicator for enemy projectiles.",
        })
        indikatorToggle(menu, tab, targets, "Familiars", "Familiars", {
            "Show this indicator for tears from familiars.",
        })
        indikatorToggle(menu, tab, targets, "FullHeartDamage", "Full heart damage only", {
            "Restrict to shots dealing a full heart or more to the player.",
        })
    end

    indikatorNumber(menu, tab, store, "MaxActiveIndicators", "Max active indicators", 0, 200, 5, 0, {
        "Caps how many of these indicators render at once.",
        "0 means unlimited.",
    })
end

-- The "mark from start to end" toggle, shown right below each type's height
-- threshold since it changes how that threshold gates the indicator.
local function indikatorMarkFromStartToEnd(menu, tab, store)
    indikatorToggle(menu, tab, store, "MarkFromStartToEnd", "Mark from start to end", {
        "Marks projectiles while still rising toward the threshold,",
        "and keeps them marked as they fall back below it.",
    })
end

-- ---- Projectile-class option builders (the full height-arc option sets) ----

local function buildProjectileMarkerOptions(menu, tab, store, color)
    indikatorSymbol(menu, tab, store, "Marker")
    mcmAddSpace(menu, tab)
    indikatorVisibility(menu, tab, store, "Visibility", "Visibility", {
        "Controls when the ground ring is drawn.",
    })
    indikatorNumber(menu, tab, store, "HeightThreshold", "Height threshold", 0, 96, 1, 0, {
        "Only projectiles reaching this height qualify as high arches.",
    })
    indikatorMarkFromStartToEnd(menu, tab, store)
    mcmAddSpace(menu, tab)
    indikatorNumber(menu, tab, store, "HeightForBottomValues", "Bottom at height", 0, 300, 2.5, 1)
    indikatorNumber(menu, tab, store, "HeightForTopValues", "Top at height", 0, 300, 2.5, 1)
    indikatorNumber(menu, tab, store, "AlphaBottom", "Alpha bottom", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "AlphaTop", "Alpha top", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "ScaleBottom", "Scale bottom", 0.05, 2, 0.05, 2)
    indikatorNumber(menu, tab, store, "ScaleTop", "Scale top", 0.05, 2, 0.05, 2)
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Projectile", color)
end

local function buildProjectileTetherOptions(menu, tab, store, color)
    indikatorSymbol(menu, tab, store, "Tether")
    indikatorNumber(menu, tab, store, "Step", "Point spacing", 0.25, 40.00, 0.25, 2)
    indikatorNumber(menu, tab, store, "Height", "Point height", 0.05, 1.50, 0.05, 2)
    mcmAddSpace(menu, tab)
    indikatorVisibility(menu, tab, store, "Visibility", "Visibility", {
        "Controls when the vertical guide to the ground is drawn.",
    })
    indikatorNumber(menu, tab, store, "HeightThreshold", "Height threshold", 0, 96, 1, 0, {
        "Only projectiles reaching this height qualify as high arches.",
    })
    indikatorMarkFromStartToEnd(menu, tab, store)
    mcmAddSpace(menu, tab)
    indikatorNumber(menu, tab, store, "HeightForBottomValues", "Bottom at height", 0, 300, 2.5, 1)
    indikatorNumber(menu, tab, store, "HeightForTopValues", "Top at height", 0, 300, 2.5, 1)
    indikatorNumber(menu, tab, store, "AlphaBottom", "Alpha bottom", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "AlphaTop", "Alpha top", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "WidthBottom", "Width bottom", 0, 5, 0.05, 2)
    indikatorNumber(menu, tab, store, "WidthTop", "Width top", 0, 5.00, 0.05, 2)
    indikatorNumber(menu, tab, store, "MinLength", "Minimum tether length", 0, 300, 2.5, 1)
    indikatorNumber(menu, tab, store, "MaxLength", "Maximum tether length", 0, 300, 2.5, 1)
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Projectile", color)
end

local function buildProjectileTrailOptions(menu, tab, store, color)
    indikatorVisibility(menu, tab, store, "Visibility", "Visibility", {
        "Controls when the short trail behind the projectile is drawn.",
    })
    indikatorNumber(menu, tab, store, "HeightThreshold", "Height threshold", 0, 96, 1, 0, {
        "Only projectiles reaching this height qualify as high arches.",
    })
    indikatorMarkFromStartToEnd(menu, tab, store)
    mcmAddSpace(menu, tab)
    indikatorSymbol(menu, tab, store, "Trail")
    indikatorNumber(menu, tab, store, "PointCount", "Point count", 1, 30, 1, 0, {
        "How many trail points are kept behind the projectile.",
    })
    indikatorNumber(menu, tab, store, "MinDistance", "Point distance", 0, 20, 0.25, 2)
    indikatorNumber(menu, tab, store, "OffsetFromMarkerCenter", "Center offset", 0, 64, 1, 0)
    mcmAddSpace(menu, tab)
    indikatorNumber(menu, tab, store, "HeightForBottomValues", "Bottom at height", 0, 300, 2.5, 1)
    indikatorNumber(menu, tab, store, "HeightForTopValues", "Top at height", 0, 300, 2.5, 1)
    indikatorNumber(menu, tab, store, "AlphaBottom", "Alpha bottom", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "AlphaTop", "Alpha top", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "ScaleBottom", "Scale bottom", 0.05, 2, 0.05, 2)
    indikatorNumber(menu, tab, store, "ScaleTop", "Scale top", 0.05, 2, 0.05, 2)
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Projectile", color)
end

local function buildProjectileNumberOptions(menu, tab, store, color)
    indikatorVisibility(menu, tab, store, "Visibility", "Visibility", {
        "Controls when the height number is drawn next to the projectile.",
    })
    indikatorNumber(menu, tab, store, "HeightThreshold", "Height threshold", 0, 96, 1, 0, {
        "Only projectiles reaching this height qualify as high arches.",
    })
    indikatorMarkFromStartToEnd(menu, tab, store)
    mcmAddSpace(menu, tab)
    indikatorNumber(menu, tab, store, "MinHeight", "Minimum height", 0, 96, 1, 0, {
        "Height text is hidden below this current air height.",
    })
    indikatorNumber(menu, tab, store, "Decimals", "Decimals", 0, 2, 1, 0)
    indikatorNumber(menu, tab, store, "Scale", "Text scale", 0.25, 2, 0.05, 2)
    indikatorNumber(menu, tab, store, "Alpha", "Text alpha", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "OffsetX", "Offset X", -64, 64, 1, 0)
    indikatorNumber(menu, tab, store, "OffsetY", "Offset Y", -64, 64, 1, 0)
    indikatorToggle(menu, tab, store, "UsePositionOffset", "Use PositionOffset", {
        "Uses the projectile's visual PositionOffset when placing the text.",
    })
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Projectile", color)
end

-- ---- Entity-class option builders (simplified: no height-arc gating; single
-- Alpha/Scale/Width driving the *Bottom/*Top pair to a constant) ----

local function buildEntityMarkerOptions(menu, tab, store, color)
    indikatorSymbol(menu, tab, store, "Marker")
    indikatorPairedNumber(menu, tab, store, "AlphaBottom", "AlphaTop", "Alpha", 0, 1, 0.05, 2)
    indikatorPairedNumber(menu, tab, store, "ScaleBottom", "ScaleTop", "Scale", 0.05, 2, 0.05, 2)
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Entity", color)
end

local function buildEntityTetherOptions(menu, tab, store, color)
    indikatorSymbol(menu, tab, store, "Tether")
    indikatorNumber(menu, tab, store, "Step", "Point spacing", 0.25, 40.00, 0.25, 2)
    indikatorNumber(menu, tab, store, "Height", "Point height", 0.05, 1.50, 0.05, 2)
    indikatorPairedNumber(menu, tab, store, "AlphaBottom", "AlphaTop", "Alpha", 0, 1, 0.05, 2)
    indikatorPairedNumber(menu, tab, store, "WidthBottom", "WidthTop", "Width", 0, 5, 0.05, 2)
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Entity", color)
end

local function buildEntityTrailOptions(menu, tab, store, color)
    indikatorSymbol(menu, tab, store, "Trail")
    indikatorNumber(menu, tab, store, "PointCount", "Point count", 1, 30, 1, 0, {
        "How many trail points are kept behind the entity.",
    })
    indikatorNumber(menu, tab, store, "MinDistance", "Point distance", 0, 20, 0.25, 2)
    indikatorNumber(menu, tab, store, "OffsetFromMarkerCenter", "Center offset", 0, 64, 1, 0)
    indikatorPairedNumber(menu, tab, store, "AlphaBottom", "AlphaTop", "Alpha", 0, 1, 0.05, 2)
    indikatorPairedNumber(menu, tab, store, "ScaleBottom", "ScaleTop", "Scale", 0.05, 2, 0.05, 2)
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Entity", color)
end

local function buildEntityNumberOptions(menu, tab, store, color)
    indikatorNumber(menu, tab, store, "Decimals", "Decimals", 0, 2, 1, 0)
    indikatorNumber(menu, tab, store, "Scale", "Text scale", 0.25, 2, 0.05, 2)
    indikatorNumber(menu, tab, store, "Alpha", "Text alpha", 0, 1, 0.05, 2)
    indikatorNumber(menu, tab, store, "OffsetX", "Offset X", -64, 64, 1, 0)
    indikatorNumber(menu, tab, store, "OffsetY", "Offset Y", -64, 64, 1, 0)
    mcmAddSpace(menu, tab)
    indikatorTargets(menu, tab, store, "Entity", color)
end

-- Maps a Type index to the function that emits its options, per Class.
local ProjectileOptionBuilders = {
    buildProjectileMarkerOptions,
    buildProjectileTetherOptions,
    buildProjectileTrailOptions,
    buildProjectileNumberOptions,
}

local EntityOptionBuilders = {
    buildEntityMarkerOptions,
    buildEntityTetherOptions,
    buildEntityTrailOptions,
    buildEntityNumberOptions,
}

-- The option builders for an instance's fixed Class.
local function indikatorOptionBuildersFor(instance)
    if IndikatorClasses[instance.Class] == "Entity" then
        return EntityOptionBuilders
    end

    return ProjectileOptionBuilders
end

-- The Type selector shown on the Create tab. It only picks the Type the next
-- created Indikator will get, so changing it neither saves Config nor rebuilds
-- the menu (the create button applies it).
local function addNewIndikatorTypeSelector(menu)
    menu.AddSetting(MOD_NAME, "Add new", {
        Type = menu.OptionType.NUMBER,
        Minimum = 1,
        Maximum = #IndikatorTypes,
        ModifyBy = 1,

        CurrentSetting = function()
            return newIndikatorType
        end,

        Display = function()
            return "Type: " .. IndikatorTypes[newIndikatorType]
        end,

        OnChange = function(value)
            newIndikatorType = clamp(math.floor((value or 1) + 0.5), 1, #IndikatorTypes)
        end,

        Info = {
            "Choose the Type for the next Indikator you create.",
        },
    })
end

-- The Class selector shown right below Type on the Create tab. Like Type, it only
-- picks what the next created Indikator gets; the create button applies it.
local function addNewIndikatorClassSelector(menu)
    menu.AddSetting(MOD_NAME, "Add new", {
        Type = menu.OptionType.NUMBER,
        Minimum = 1,
        Maximum = #IndikatorClasses,
        ModifyBy = 1,

        CurrentSetting = function()
            return newIndikatorClass
        end,

        Display = function()
            return "Targets: " .. IndikatorClasses[newIndikatorClass]
        end,

        OnChange = function(value)
            newIndikatorClass = clamp(math.floor((value or 1) + 0.5), 1, #IndikatorClasses)
        end,

        Info = {
            "Projectiles: tears / enemy shots (full height options).",
            "Entities: enemies / familiars / player (simpler options).",
        },
    })
end

-- Short, per-Type explanations shown under the Type selector on the Create tab.
-- Each entry is a list of lines; MCM renders one option row per line and does
-- not wrap, so keep every line short (~40 chars). All entries use the same line
-- count so the layout below stays put as the selected Type changes.
local IndikatorTypeDescriptions = {
    { -- Marker
        "A ring drawn flat on the ground at the",
        "spot a tear or projectile will land.",
        "Best for reading where shots come down.",
    },
    { -- Tether
        "A dotted vertical line linking a shot in",
        "the air to its spot on the ground.",
        "Shows how high it currently is.",
    },
    { -- Trail
        "A short fading trail left behind a shot",
        "as it travels through the air.",
        "Best for following fast projectiles.",
    },
    { -- Number
        "The shot's current air height drawn as",
        "a number next to it.",
        "Best for exact height readouts.",
    },
}

-- Longest description, so every Type reserves the same number of text rows.
local IndikatorDescriptionLines = 0
for _, desc in ipairs(IndikatorTypeDescriptions) do
    if #desc > IndikatorDescriptionLines then
        IndikatorDescriptionLines = #desc
    end
end

-- Emits the live description block. Each row re-reads newIndikatorType every
-- render via its Display function, so the text updates the instant the Type
-- selector changes (no menu rebuild needed).
local function addNewIndikatorDescription(menu)
    for line = 1, IndikatorDescriptionLines do
        mcmAddText(menu, "Add new", function()
            local desc = IndikatorTypeDescriptions[newIndikatorType]
            return desc and desc[line] or ""
        end)
    end
end

-- Maps a tab (subcategory) name to its live instance + type, rebuilt every time
-- the tabs are. The settings preview uses MCM's current subcategory name to find
-- the store it should draw.
local previewTabs = {}

-- Builds one Indikator tab: a delete button, then the options for the
-- instance's Type and Class (both chosen on the Create tab when the tab was
-- made). Titles are tinted by Class (blue = Projectile, orange = Entity).
local function buildIndikatorTab(menu, tab, instance)
    -- mcmAddTitle(menu, tab, tab)

    addActionButton(menu, tab, "Delete this indicator", {
        "Delete " .. tab .. "?",
        "",
        "Confirm to remove it,",
        "or go back to keep it.",
    }, function()
        deleteIndikator(instance)
    end,
    true)

    mcmAddSpace(menu, tab)

    local color = INDIKATOR_CLASS_COLORS[instance.Class]
    local className = IndikatorClasses[instance.Class] or "Projectile"

    mcmAddTitle(menu, tab, className .. " " .. IndikatorTypes[instance.Type] .. " options", color)

    local typeKey = IndikatorTypes[instance.Type]
    local builders = indikatorOptionBuildersFor(instance)
    local builder = builders[instance.Type] or builders[1]
    builder(menu, tab, instance[typeKey], color)
end

-- Builds every Indikator page, then the "Add new" hub as the LAST
-- subcategory. Order matters: a new tab is appended to Config.Indikators, so it
-- lands in the subcategory slot the "Add new" tab occupied before the
-- rebuild. Because MCM keeps the cursor on that slot index across a rebuild,
-- creating a tab jumps straight to the new tab (see createIndikator).
--
-- Tabs are named by their Type plus a per-Type running number, e.g. "Marker 1",
-- "Tether 1", "Marker 2". Per-Type counting keeps every tab name unique (MCM
-- keys subcategories by name) while staying readable.
local function buildIndikatorTabs(menu)
    local typeCounts = {}
    previewTabs = {}

    for _, instance in ipairs(Config.Indikators) do
        local typeName = IndikatorTypes[instance.Type]
        typeCounts[typeName] = (typeCounts[typeName] or 0) + 1

        local tabName = typeName .. " " .. typeCounts[typeName]
        previewTabs[tabName] = { instance = instance, typeName = typeName }
        buildIndikatorTab(menu, tabName, instance)
    end

    mcmAddTitle(menu, "Add new", "Create new indikators")

    mcmAddSpace(menu, "Add new")

    addNewIndikatorTypeSelector(menu)
    addNewIndikatorClassSelector(menu)

    addActionButton(menu, "Add new", "Create!", {
        "Create a new Indikator tab?",
        "",
        "Confirm to add it,",
        "or go back to cancel.",
    }, createIndikator,
    false)

    mcmAddSpace(menu, "Add new")

    addNewIndikatorDescription(menu)
end

-- Builds (or fully rebuilds) the entire mod category. Safe to call repeatedly;
-- it clears the category first so dynamic tabs reflect the current config.
local function buildModConfigMenu(menu)
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

    addResetDefaultsSetting(menu)

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

    -- Debug
    mcmAddTitle(menu, "Debug", "Debug Text")

    addYesNoSetting(menu, "Debug", "Enabled", { "General", "DebugText" }, {
        "Shows small debug counts in the top-left corner.",
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

    mcmAddSpace(menu, "Debug")

    mcmAddTitle(menu, "Debug", "Preview")

    addYesNoSetting(menu, "Debug", "Show settings preview", { "Preview", "Enabled" }, {
        "Draws a live preview over an indicator's tab while you edit it.",
    })

    -- Indikator tabs: the "Create Indikators" hub followed by each instance.
    buildIndikatorTabs(menu)
end

-- Performs a full rebuild of the live menu. Called after dynamic tabs change.
local function rebuildModConfigMenu()
    local menu = getModConfigMenu()
    if menu == nil or menu.AddSetting == nil or menu.OptionType == nil then
        return
    end

    buildModConfigMenu(menu)
end

local function setupModConfigMenu()
    if mcmRegistered then
        return
    end

    local menu = getModConfigMenu()
    if menu == nil or menu.AddSetting == nil or menu.OptionType == nil then
        return
    end

    buildModConfigMenu(menu)

    mcmRegistered = true
    Isaac.DebugString(MOD_NAME .. ": Mod Config Menu registered")
end

-- Applies any deferred menu rebuild requested by the dynamic-tab buttons.
-- Runs outside MCM's render pass so we never mutate it mid-frame.
local function flushPendingMenuRebuild()
    if not pendingMenuRebuild then
        return
    end

    pendingMenuRebuild = false
    rebuildModConfigMenu()
end

-- ============================================================================
-- Settings preview (drawn over the Mod Config Menu)
--
-- While an Indikator tab is open, draw a small live panel showing how that
-- indicator looks, using the shared screen-space render cores. It reacts to the
-- tab's values as you change them, and when a bottom/top option is focused it
-- holds the preview at that height end (PreviewHeight hint); otherwise it loops
-- a rising/falling sample so trails build and tethers grow/shrink.
-- ============================================================================

-- Our own render-frame counter; Game():GetFrameCount can freeze while the menu
-- is open, so the animation ticks on this instead.
local previewFrame = 0

local PREVIEW_LOOP = 200
local PREVIEW_BOX_W = 60
local PREVIEW_BOX_H = 110
local PREVIEW_MARGIN = 20
local PREVIEW_TOP_PAD = 10    -- height-axis ceiling, below the header
local PREVIEW_BOTTOM_PAD = 10 -- ground line, above the bottom label
local PANEL_SRC = 16 -- preview_panel.png is a 16x16 solid white cell

-- Trail preview spacing. Point spacing is MinDistance scaled into preview pixels
-- (so the gap visibly tracks the Minimum distance setting), with a floor so points
-- stay distinct at tiny distances. previewTrailPoints then caps how many points
-- fit in the panel, so raising Point count lengthens the trail instead of
-- squeezing the existing points together.
local PREVIEW_TRAIL_SPACING_SCALE = 0.5
local PREVIEW_TRAIL_MIN_SPACING = 3

-- Lazily loaded solid-fill sprite used to paint the preview's panel, border and
-- guide lines. Self-contained asset so it never touches the indicator sheet.
local previewPanelSprite = nil
local previewPanelTried = false

local function getPreviewPanelSprite()
    if previewPanelTried then
        return previewPanelSprite
    end

    previewPanelTried = true

    local ok = pcall(function()
        local s = Sprite()
        s:Load("gfx/indicator/preview_panel.anm2", true)
        s:SetFrame("Panel", 0)
        previewPanelSprite = s
    end)

    if not ok or previewPanelSprite == nil or not previewPanelSprite:IsLoaded() then
        previewPanelSprite = nil
    end

    return previewPanelSprite
end

-- Fills the screen rect (x, y, w, h) with a tinted, alpha-blended solid color.
-- No-op if the panel sprite failed to load (the preview still draws without it).
local function drawPanelRect(x, y, w, h, r, g, b, a)
    local s = getPreviewPanelSprite()
    if s == nil then
        return
    end

    s.Color = Color(r, g, b, a)
    s.Scale = Vector(w / PANEL_SRC, h / PANEL_SRC)
    s.Rotation = 0
    s:Render(Vector(x, y), ZERO_VECTOR, ZERO_VECTOR)
end

-- Triangle wave in [0,1] over PREVIEW_LOOP frames (0 -> 1 -> 0).
local function previewTriangle()
    local phase = (previewFrame % PREVIEW_LOOP) / PREVIEW_LOOP
    return 1 - math.abs(phase * 2 - 1)
end

-- Screen points for the Trail preview. Like the live trail it lies flat on the
-- ground (the trail follows the projectile's ground track, not its height), with
-- the newest point at the tear's ground X and older points trailing left.
--
-- Spacing is driven by MinDistance (the in-game sample distance) at a fixed
-- preview scale, with a small floor so points stay distinct when MinDistance is
-- tiny. The trail is then capped to the points that actually fit between the tear
-- and the panel's left edge, so raising Point count lengthens the trail until it
-- fills the panel rather than squeezing the existing points together.
-- Oldest first; renderTrailCore drops the last point.
local function previewTrailPoints(store, tearGroundX, groundY, leftBound)
    local requested = math.max(2, math.floor((store.PointCount or 5) + 0.5))

    local spacing = math.max((store.MinDistance or 0) * PREVIEW_TRAIL_SPACING_SCALE, PREVIEW_TRAIL_MIN_SPACING)

    local fits = math.floor((tearGroundX - leftBound) / spacing) + 1
    local n = math.max(2, math.min(requested, fits))

    local points = {}
    for i = 1, n do
        points[i] = Vector(tearGroundX - (n - i) * spacing, groundY)
    end

    return points
end

local PREVIEW_COLOR = { 0.8, 0.8, 0.8 }

-- The axis value the tear snaps to when a height-linked option is focused (nil =
-- animate). Tether lengths resolve onto the same shared axis as air heights.
local function previewSnapHeight(hint, store)
    if hint == "bottom" then
        return store.HeightForBottomValues
    elseif hint == "top" then
        return store.HeightForTopValues
    elseif hint == "minlen" then
        return store.MinLength
    elseif hint == "maxlen" then
        return store.MaxLength
    elseif hint == "threshold" then
        return store.HeightThreshold
    end

    return nil
end

-- A faint labelled reference line across the panel at axis value `v`; the focused
-- property's line is brightened.
local function drawHeightMarker(boxX, valueToY, v, text, focused)
    if v == nil then
        return
    end

    local y = valueToY(v)
    drawPanelRect(boxX + 4, y, PREVIEW_BOX_W - 8, 0.5, 0.55, 0.60, 0.72, focused and 0.9 or 0.35)
    renderText(text, boxX + 5, y - 6, 0.5, 0.5, 0.80, 0.85, 0.95, focused and 1 or 0.6)
end

local function drawSettingsPreview()
    if not (Config.Preview and Config.Preview.Enabled) then
        return
    end

    local menu = getModConfigMenu()
    if menu == nil or not menu.IsVisible then
        return
    end

    if menu.CurrentCategory == nil or menu.CurrentCategory.Name ~= MOD_NAME then
        return
    end

    local sub = menu.CurrentSubcategory
    local tab = sub ~= nil and previewTabs[sub.Name] or nil
    if tab == nil then
        return
    end

    local store = tab.instance[tab.typeName]
    if store == nil then
        return
    end

    previewFrame = previewFrame + 1

    -- Panel pinned to the right edge, vertically centered.
    local boxX = Isaac.GetScreenWidth() - PREVIEW_BOX_W - 15
    local boxY = (Isaac.GetScreenHeight() - PREVIEW_BOX_H) * 0.45
    local groundY = boxY + PREVIEW_BOX_H - PREVIEW_BOTTOM_PAD
    local ceilingY = boxY + PREVIEW_TOP_PAD
    local usableSpan = groundY - ceilingY
    local tearGroundX = boxX + PREVIEW_BOX_W * .5
    local leftBound = boxX + 10

    -- Shared vertical axis: an air height (or, for the Tether, a length) maps to a
    -- Y. Everything that gets a marker is folded into axisMax so each line lands
    -- on-axis, with 10% headroom so the topmost marker clears the ceiling.
    local topValue = store.HeightForTopValues or 100
    local axisMax = math.max(
        topValue,
        store.HeightThreshold or 0,
        store.HeightForBottomValues or 0,
        store.MinLength or 0,
        store.MaxLength or 0,
        1
    ) * 1.1

    local pxPerUnit = usableSpan / axisMax
    local function valueToY(v)
        return groundY - clamp(v * pxPerUnit, 0, usableSpan)
    end

    -- The tear oscillates from the ground (0) up to "Top at height", unless a
    -- height-linked option is focused, in which case it snaps to that value.
    local hint = menu.CurrentOption ~= nil and menu.CurrentOption.PreviewHeight or nil
    local currentHeight = previewSnapHeight(hint, store)
    if currentHeight == nil then
        currentHeight = lerp(0, topValue, previewTriangle())
    end
    currentHeight = math.max(currentHeight, 0)

    local tearAirPos = Vector(tearGroundX, valueToY(currentHeight))
    local groundScreenPos = Vector(tearGroundX, groundY)

    -- Background: light border, dark panel, ground line.
    drawPanelRect(boxX - 2, boxY - 2, PREVIEW_BOX_W + 4, PREVIEW_BOX_H + 4, 0.43, 0.43, 0.43, 0.90)
    drawPanelRect(boxX, boxY, PREVIEW_BOX_W, PREVIEW_BOX_H, 0.10, 0.10, 0.10, 1.00)
    drawPanelRect(boxX + 4, groundY, PREVIEW_BOX_W - 8, 1, 0.30, 0.30, 0.30, 1.00)

    -- Reference markers for the height-linked properties this type has.
    drawHeightMarker(boxX, valueToY, store.HeightForBottomValues, "Bot", hint == "bottom")
    drawHeightMarker(boxX, valueToY, store.HeightForTopValues, "Top", hint == "top")
    drawHeightMarker(boxX, valueToY, store.HeightThreshold, "Thr", hint == "threshold")
    if tab.typeName == "Tether" then
        drawHeightMarker(boxX, valueToY, store.MinLength, "Min", hint == "minlen")
        drawHeightMarker(boxX, valueToY, store.MaxLength, "Max", hint == "maxlen")
    end

    local rgb = getColorPreset().PlayerTear

    -- Faint vertical guide from the ground up to the tear (Tether draws its own).
    if tab.typeName ~= "Tether" and tearAirPos.Y < groundY - 1 then
        drawPanelRect(tearGroundX - 0.25, tearAirPos.Y, 0.5, groundY - tearAirPos.Y, 0.45, 0.50, 0.60, 0.35)
    end

    if tab.typeName == "Marker" then
        renderMarkerIndikator(store, rgb, groundScreenPos, currentHeight)
    elseif tab.typeName == "Tether" then
        -- renderTetherCore checks Min/MaxLength in screen pixels; scale them onto
        -- the preview axis so the cap/hide behaviour lines up with the markers.
        local tetherStore = setmetatable({
            MinLength = math.max(0, (store.MinLength or 0) * pxPerUnit - 7),
            MaxLength = (store.MaxLength or 0) * pxPerUnit,
        }, { __index = store })
        renderTetherCore(tetherStore, rgb, groundScreenPos, tearAirPos, currentHeight)
    elseif tab.typeName == "Trail" then
        renderTrailCore(store, rgb, previewTrailPoints(store, tearGroundX, groundY, leftBound), currentHeight)
    elseif tab.typeName == "Number" then
        renderNumberCore(store, rgb, tearAirPos, currentHeight)
    end

    -- The tear itself (white, on top) and a readout of its current height.
    drawIndicatorSprite("Center", tearAirPos, 0.5, 1.0, PREVIEW_COLOR, 0.95, 0.5)
    renderText("h " .. tostring(math.floor(currentHeight + 0.5)), tearGroundX + 6, tearAirPos.Y - 4, 0.5, 0.5, 1, 1, 1, 0.9)

    -- Header: the tab name.
    renderText("Preview", boxX + 19, boxY + 2, 0.5, 0.5, 0.8, 0.8, 0.8, 1.00)
    -- renderText("Preview", boxX + 15, boxY + 2, 0.7, 0.7, 0.7, 0.7, 0.7, 1.00)
end

-- ============================================================================
-- Callbacks
-- ============================================================================

function Indicator:OnPostUpdate()
    setupModConfigMenu()
    flushPendingMenuRebuild()

    if not Config.General.Enabled then
        return
    end

    local entities = Isaac.GetRoomEntities()

    for _, entity in ipairs(entities) do
        local info = classifyEntity(entity)

        if info ~= nil and passesBaseEntityChecks(entity) then
            if entityWantedByAnyIndikator(info) then
                getOrCreateEntityState(entity, info)
            end
        end
    end

    pruneEntityStates()

    -- Per-Indikator qualification, slot allocation, and trail sampling.
    updateIndikatorRuntime()
end

function Indicator:OnPostRender()
    setupModConfigMenu()

    -- Drawn before the Enabled gate so the preview works while configuring even
    -- with the mod's in-game drawing turned off.
    drawSettingsPreview()

    if not Config.General.Enabled then
        return
    end

    local projectileCount = 0
    local entityCount = 0
    local shownCount = 0
    local debug = Config.General.DebugText

    local entities = Isaac.GetRoomEntities()

    for _, entity in ipairs(entities) do
        -- Debug counts include every classifiable entity, tracked or not; the
        -- classify is skipped entirely when the readout is off.
        if debug then
            local info = classifyEntity(entity)
            if info ~= nil then
                if info.Class == "Projectile" then
                    projectileCount = projectileCount + 1
                else
                    entityCount = entityCount + 1
                end
            end
        end

        if passesBaseEntityChecks(entity) then
            local state = entityStates[getEntityKey(entity)]

            -- Only tracked entities can render; their Source (set at track time)
            -- drives the color, so no re-classify is needed here.
            if state ~= nil then
                local rgb = sourceColor(state.Source)
                local groundScreenPos = worldToScreen(entity.Position)
                local currentHeight = getCurrentAirHeight(entity)
                local rendered = false

                for _, inst in ipairs(Config.Indikators) do
                    if indikatorMatches(inst, state) then
                        local slot = state.Indi[inst]

                        -- The visibility mode + Max-active cap already decided
                        -- this in updateIndikatorRuntime via the Active slot.
                        if slot ~= nil and slot.Active then
                            local store = indikatorStore(inst)
                            renderIndikator(inst, store, entity, state, rgb, groundScreenPos, currentHeight)
                            rendered = true
                        end
                    end
                end

                if rendered then
                    shownCount = shownCount + 1
                end
            end
        end
    end

    if Config.General.DebugText then
        Isaac.RenderText(MOD_NAME .. " " .. VERSION, 8, 28, 0.3, 1, 1, 1)
        Isaac.RenderText(
            string.format(
                "projectiles=%d entities=%d shown=%d indikators=%d",
                projectileCount,
                entityCount,
                shownCount,
                #Config.Indikators
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

-- Render late so the menu preview (and in-game overlays) draw on top of the Mod
-- Config Menu, which registers POST_RENDER at default priority. Falls back to a
-- plain callback if the priority API is unavailable.
if Indicator.AddPriorityCallback ~= nil and CallbackPriority ~= nil and CallbackPriority.LATE ~= nil then
    Indicator:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, CallbackPriority.LATE, Indicator.OnPostRender)
else
    Indicator:AddCallback(ModCallbacks.MC_POST_RENDER, Indicator.OnPostRender)
end

Indicator:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, Indicator.OnNewRoom)
Indicator:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, Indicator.OnGameStarted)

if ModCallbacks.MC_PRE_GAME_EXIT ~= nil then
    Indicator:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, Indicator.OnPreGameExit)
end

setupModConfigMenu()

Isaac.DebugString(MOD_NAME .. " " .. VERSION .. " loaded")