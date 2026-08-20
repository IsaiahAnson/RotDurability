-- RotDurability v2.6: uses remaining + DPS instead of a percentage, for Grain Rot
-- ("Helden", UE 5.7) + UE4SS.
--
-- Problem (suggestions-feedback, mitzapper2 "Absolute Durability", 6 upvotes):
--   "I can't compare the durability between two items I'm deciding between in
--    the shop, because they both just say 100%. I think the durability should
--    be displayed in number of uses remaining (out of maximum?) when
--    inspecting, not percentage."
-- Seconded by Foxboi, who also points out the percentage is redundant: there is
-- already a durability BAR on the inventory slot, so a second percentage in the
-- detailed panel says nothing new. Hence full replacement, not an addition.
--
-- Live proof of the problem, from one shop visit: Grainbreaker 300, Rot Burner
-- 250, Nail Spitter 200, Scrap Blaster 100 - four weapons whose real lifespans
-- differ 3x, all displaying "100%".
--
-- Where the numbers live (CXXHeaderDump + RUNTIME VERIFIED 2026-08-19):
--   UHeldenInspectContentWidget - native base of the inspect panels. Intake is
--     NotifyOnNewObject on this class; it does catch the BP subclasses
--     (WBP_Inspect_Item_C / _Construct_C / _Treasure_C / _Character_C - note
--     Character is a fourth panel not listed in the item/construct/treasure
--     trio, so nothing here may assume a fixed set).
--   FHeldenInspectItemData.Durability : FRangedFloat
--     FRangedFloat is declared {min,max}, and .min is the CURRENT value -
--     verified: a full Grainbreaker read 300.00/300.00 against MaxDurability
--     300.0 reported independently by the shop probe below. Only the ITEM
--     panel has this field; the others read nil and drop out on their own.
--   THE VALUE IS IN Health_Text, NOT Durability_label. Durability_label is the
--     caption and literally contains "Durability:" - writing to it would
--     destroy the label. The panel is found by matching the percentage on
--     screen, never by property name, which is what caught this.
--   FHeldenItemData.UseDurabilityLoss - the per-use cost, needed to turn points
--     into uses. It VARIES: measured 1 (Shredder), 5 (Rust Bonk) and 10 (Grain
--     Splitter), so 200/150/100 durability is really 200/30/10 uses - a 20x
--     spread behind three identical "100%" readouts. UHeldenBuyItemWidget::OnSetup is the ONLY reflected surface in
--     the game that exposes FHeldenItemData (grep confirms: that function and
--     its BP override, nothing else), because UDataTable::RowMap is not
--     reflected. So the value is captured when you browse a shop and cached to
--     disk. Observed so far: Grainbreaker = 1.0.
--   Discovered BP path (not in the header dump):
--     /Game/UI/Shop/WBP_BuyItemWidget.WBP_BuyItemWidget_C
--
-- CLIENT-SIDE AND COSMETIC: rewrites text in a UI widget on this machine. No
-- gameplay value changes, nothing is sent, nobody else sees a difference. Safe
-- as host or joiner, safe unmatched.
--
-- Landmines respected (RotScaling / GripAndFlip / CoinBeams / RotBooster):
--   * No LoopAsync/ExecuteWithDelay timers (fatal). Per-frame BP hook only,
--     rate-limited on os.clock - the anim hook fires per ABP instance, so
--     frame counts are not time.
--   * No FKey / IsInputKeyDown / key pollers. No hotkeys.
--   * FindAllOf only as a warmup + slow catch-up sweep, never per frame.
--   * BP hooks registered lazily off a live instance; pcall + error cap.
--   * Hot reload only while solo/idle (per-frame hook = teardown race).
--
-- v0.1 -> v1.0:
--   * uses remaining rather than raw points, via the shop-probe cache
--   * self-recognition: a panel re-tracked under a changed full name used to
--     fail to bind, because the only text on screen was this mod's own output
--     ("no block reads 100%")
--   * percentage match tolerates +/-1 - a damaged item logged "no block reads
--     92%", and the game's rounding need not match ours
--   * panel registry capped; FName fields stringified in the probe log

local CFG = {
    -- What to do when the per-use cost has NOT been measured for an item.
    --
    -- Left true on the strength of a single sample (Grainbreaker, 1.0/use) and
    -- it was wrong: three shop items measured 1, 5 and 10 durability per use.
    -- Assuming 1.0 would have called a 10-use Grain Splitter "100 / 100 uses".
    -- A confidently wrong use count is worse than an honest point count, so an
    -- unmeasured item now shows bare points ("100 / 100") and only a measured
    -- one is labelled in uses.
    ASSUME_ONE_USE_PER_POINT = false,

    SHOW_PERCENT  = false,  -- true -> "276 / 300 uses  92%"

    REFRESH_HZ    = 10,
    MAX_PANELS    = 24,     -- registry cap; panels are built per inspect
    PERCENT_SLOP  = 1,      -- rounding tolerance when matching the block

    DIAG          = false,  -- the full text-block inventory of every panel
    DIAG_MAX      = 30,
    ERROR_CAP     = 10,
    WALK_DEPTH    = 12,
    PICK_RETRY_SECS = 1.0,

    SWEEP_WARMUP  = 180,
    RESWEEP_SECS  = 20,

    -- DPS. Damage per hit is on the panel already; the cadence is not a number
    -- anywhere for melee, so it is measured from real attacks (see below).
    SHOW_DPS          = true,
    SPEED_MIN_SAMPLES = 7,     -- GAPS, so 8 swings; N swings give N-1 gaps
    SPEED_MAX_SAMPLES = 20,    -- rolling window the estimate is taken over
    SPEED_PERCENTILE  = 0.25,  -- which way up the sorted gaps to read; see Floor
    SPEED_MIN_GAP     = 0.05,  -- below this it is one attack counted twice
    SPEED_MAX_GAP     = 3.0,   -- above this you simply stopped attacking
    SPEED_MAX_ACTORS  = 64,    -- per-instance memo cap
    SPEED_CALIBRATE   = true,  -- log FireRate beside measurements, to learn its unit

    -- Learning the per-use durability cost by USING a weapon, for dungeon loot
    -- that no shop sells and whose cost therefore has no other source.
    COST_BY_USE      = true,
    COST_MIN_SAMPLES = 3,      -- consecutive drops that must agree exactly
    COST_MAX_DELTA   = 60,     -- a bigger drop is breakage or a repair, not a use

    PROBE_SHOP    = true,   -- learn UseDurabilityLoss from the shop
    PROBE_LOG     = true,
}

local function Log(msg) print("[RotDurability] " .. tostring(msg) .. "\n") end

local S = {
    frame = 0, errCount = 0, diag = 0,
    panels = {},          -- [key] = { w, tb, last, nextPick, note, dumped, seq }
    nPanels = 0, seq = 0,
    applied = 0, learned = 0, measured = 0,
    nextTick = 0, nextStatus = 0, nextResweep = 0, nextSpeedSave = 0,
    hooked = false, sweepDone = false, warnedDelegate = false, everBound = false,
    infoWidgets = {},   -- key -> { w }; identity source for the uses lookup
    shopHooks = {},
}

-- ---------------------------------------------------------------- helpers

-- UE4SS hands hook params and some property reads back as wrappers; `:get()`
-- unwraps them. Tolerate a raw value too - the build varies (RotBooster).
local function Unwrap(v)
    if type(v) == "userdata" and v.get then
        local ok, got = pcall(function() return v:get() end)
        if ok and got ~= nil then return got end
    end
    return v
end

local function IsLive(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function ClassOf(o)
    local n = ""
    pcall(function()
        local full = o:GetFullName()
        if full then n = tostring(full):match("^(%S+)") or "" end
    end)
    return n
end

local function NameOf(o)
    local n = "?"
    pcall(function()
        local full = o:GetFullName()
        if full then n = tostring(full):match("([^%.%/]+)$") or "?" end
    end)
    return n
end

local function TextOf(tb)
    local s
    pcall(function()
        local t = tb:GetText()
        if t then s = tostring(t:ToString()) end
    end)
    return s
end

-- FName/FText/FString all answer ToString; plain values fall through.
local function Str(v)
    if v == nil then return nil end
    local s
    pcall(function() s = tostring(v:ToString()) end)
    if s == nil then s = tostring(v) end
    return s
end

-- A bare percentage: "100%", " 87 % ". Deliberately anchored, and deliberately
-- rejecting a leading sign - that is what keeps crit chance ("+0%") out.
local function AsPercent(s)
    if not s then return nil end
    local n = s:match("^%s*(%d+)%s*%%%s*$")
    return n and tonumber(n) or nil
end

-- ------------------------------------------------------------- uses cache
--
-- Keyed on UHeldenItemDataAsset.UniqueName: the shop hands us that asset as
-- InAsset, and every equipable item carries the same asset back on
-- .ItemDataAsset, so the key the shop writes is the key the panel reads.
-- Persisted as a Lua literal in the game's Saved dir, the way RotHub persists
-- settings - a real path on disk even under shimloader, whose virtual paths
-- only resolve inside the game process.

-- Costs measured from the base game. They exist because the cost is only
-- learned when the BUY widget appears, which is one interaction later than the
-- first look at an item on the shelf - so without these, the first time you
-- inspect anything it has no cost yet and falls back to points. Shipping the
-- measured values means the common case is right on first contact.
--
-- Anything learned at runtime overrides these, so a balance patch corrects
-- itself the next time you browse that item in a shop.
local DEFAULT_COSTS = {
    ["GlueGun_01"]         = { loss = 1,  max = 100, name = "Splinter Cream" },
    ["GrapplingHook_01"]   = { loss = 3,  max = 100, name = "Clutch Hook" },
    ["GrenadeLauncher_01"] = { loss = 10, max = 120, name = "Boom Tube" },
    ["HandSaw_01"]         = { loss = 1,  max = 200, name = "Shredder" },
    ["Knife_01"]           = { loss = 5,  max = 75,  name = "Small Cutter" },
    ["Machete_01"]         = { loss = 5,  max = 100, name = "Sawtooth" },
    -- Measured in play (10 shots cost 50 points), not from a shop, so the real
    -- asset key is still unknown; "~" marks a name-only entry, which cannot
    -- collide with a UniqueName and is resolved by LossForName. If a shop ever
    -- sells one, the learned entry lands under the real key and wins.
    ["~NailSpitter"]       = { loss = 5,  max = 200, name = "Nail Spitter" },
    -- Confirmed in play as well as by the probe: 30 swings cost exactly 30
    -- points. Same 300 durability as the Iron Bonk but five times the uses,
    -- which is the comparison the old "100%" display hid.
    ["Malet_02"]           = { loss = 1,  max = 300, name = "Grainbreaker" },
    ["Shotgun_01"]         = { loss = 5,  max = 100, name = "Scrap Blaster" },
    ["Sniper_01"]          = { loss = 10, max = 100, name = "Grain Splitter" },
    ["Spear_01"]           = { loss = 3,  max = 100, name = "Poke Stick" },
    ["SpikeClub_01"]       = { loss = 5,  max = 150, name = "Rust Bonk" },
    ["SpikeClub_Elite_01"] = { loss = 5,  max = 300, name = "Iron Bonk" },
}

local Uses = { map = {}, dirty = false, path = nil, loaded = false }

function Uses.resolvePath()
    local dir
    pcall(function()
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if ksl and ksl:IsValid() then
            local s = ksl:GetProjectSavedDirectory()
            if s then
                s = s:ToString()
                if s and #s > 3 then dir = s end
            end
        end
    end)
    if not dir then
        local app = os.getenv("APPDATA")
        if app then dir = app .. "\\" end
    end
    if not dir then dir = "" end
    local last = dir:sub(-1)
    if last ~= "\\" and last ~= "/" then dir = dir .. "\\" end
    return dir .. "RotDurability.uses.lua"
end

function Uses.load()
    if Uses.loaded then return end
    Uses.loaded = true
    Uses.path = Uses.resolvePath()
    for k, v in pairs(DEFAULT_COSTS) do
        Uses.map[k] = { loss = v.loss, max = v.max, name = v.name, bundled = true }
    end
    pcall(function()
        local f = io.open(Uses.path, "r")
        if not f then return end
        local raw = f:read("*a")
        f:close()
        if not raw or raw == "" then return end
        local chunk = load(raw, "rotdur", "t", {})   -- empty env: data only
        if not chunk then return end
        local ok, val = pcall(chunk)
        if ok and type(val) == "table" then
            local n = 0
            for k, v in pairs(val) do
                if type(v) == "table" and v.loss then
                    Uses.map[k] = v            -- learned overrides bundled
                    n = n + 1
                end
            end
            if n > 0 then Log(string.format("loaded %d learned item costs", n)) end
        end
    end)
end

function Uses.save()
    if not Uses.dirty or not Uses.path then return end
    Uses.dirty = false
    pcall(function()
        local keys = {}
        for k, e in pairs(Uses.map) do
            if not e.bundled then keys[#keys + 1] = k end   -- learned only
        end
        table.sort(keys)
        local f = io.open(Uses.path, "w")
        if not f then return end
        f:write("-- RotDurability: per-use durability costs learned from shops.\n")
        f:write("-- Safe to delete; it refills as you browse.\n")
        f:write("return {\n")
        for _, k in ipairs(keys) do
            local e = Uses.map[k]
            f:write(string.format(
                "  [%q] = { loss = %.6g, max = %.6g, name = %q, src = %q, placeholder = %s },\n",
                k, e.loss or 0, e.max or 0, e.name or "", e.src or "shop",
                e.placeholder and "true" or "false"))
        end
        f:write("}\n")
        f:close()
    end)
end

function Uses.put(key, loss, max, name)
    if not key or type(loss) ~= "number" or loss <= 0 then return false end
    local old = Uses.map[key]
    if old and math.abs((old.loss or 0) - loss) < 1e-6 then return false end
    Uses.map[key] = { loss = loss, max = max, name = name }
    Uses.dirty = true
    S.learned = S.learned + 1
    return true
end

function Uses.lossFor(key)
    local e = key and Uses.map[key]
    return e and e.loss or nil
end

local function AssetKeyOf(asset)
    if asset == nil then return nil end
    local k = Str(asset.UniqueName)
    if k == nil or k == "" or k == "None" then k = NameOf(asset) end
    if k == "" or k == "?" then return nil end
    return k
end

-- ------------------------------------------------------------- attack speed
--
-- DPS needs damage-per-hit and hits-per-second. The first is already on the
-- panel; the second does not exist as a number anywhere for melee. Timing lives
-- in UAnimMontage assets reached through AHeldenWeapon.AttackAnimChain, and
-- deriving a cadence from SequenceLength would be wrong in three ways at once:
-- FHeldenMontage.Sections means only part of a montage may play, the chain is a
-- COMBO so successive swings differ, and BlendOutTriggerTime lets the next
-- attack start before the current one finishes. A number derived from that
-- would look authoritative and be wrong - the same trap LossForMax fell into.
--
-- So it is measured instead: AHeldenWeapon:Attack_Multicast fires once per
-- attack on every machine, and the gap between consecutive attacks of the SAME
-- weapon actor is the real cadence, combos and cancels included. Median of the
-- samples, because a stray long gap (you stopped swinging) must not drag the
-- average. Kept per weapon NAME, which is what the panel can look itself up by.
-- Measured cadences shipped with the mod, so a weapon shows its DPS the first
-- time you look at it - on a shop shelf, before buying, which is exactly where
-- comparing two weapons matters and where you cannot swing one to find out.
--
-- Melee values came from real swings; the guns are their stated FireRate. Most
-- of the melee ones predate the Floor estimator and so read slightly SLOW,
-- which understates DPS a little. That is the safe direction, and the monotonic
-- rule walks each one down to its true floor as you play.
local DEFAULT_SPEEDS = {
    -- melee, measured
    ["Golden Mallet"]  = { interval = 0.328, proj = 1 },
    ["Grainbreaker"]   = { interval = 0.316, proj = 1 },
    ["Iron Bonk"]      = { interval = 0.658, proj = 1 },
    ["Mallet"]         = { interval = 0.332, proj = 1 },
    ["Poke Stick"]     = { interval = 0.482, proj = 1 },
    ["Rust Bonk"]      = { interval = 0.786, proj = 1 },
    ["Sawtooth"]       = { interval = 0.456, proj = 1 },
    ["Shadespear"]     = { interval = 0.457, proj = 1 },
    ["Shredder"]       = { interval = 0.502, proj = 1 },
    ["Small Cutter"]   = { interval = 0.484, proj = 1 },
    -- ranged, stated cooldown; re-read live whenever the weapon is in front of us
    ["Boom Tube"]      = { interval = 0.500, proj = 1 },
    ["Grain Splitter"] = { interval = 1.500, proj = 1 },
    ["Nail Spitter"]   = { interval = 0.150, proj = 1 },
    ["Rot Burner"]     = { interval = 0.150, proj = 1 },
    ["Scrap Blaster"]  = { interval = 1.000, proj = 5 },
    ["Splinter Cream"] = { interval = 0.100, proj = 1 },
}

local Speed = { map = {}, dirty = false, path = nil, loaded = false }
local Actors = {}          -- instance name -> { name, last }; bounded
local nActors = 0

function Speed.resolvePath()
    local p = Uses.resolvePath()
    return (p:gsub("%.uses%.lua$", ".speed.lua"))
end

function Speed.load()
    if Speed.loaded then return end
    Speed.loaded = true
    Speed.path = Speed.resolvePath()
    for k, v in pairs(DEFAULT_SPEEDS) do
        Speed.map[k] = { interval = v.interval, proj = v.proj, samples = 0,
                         src = "bundled", bundled = true }
    end
    pcall(function()
        local fh = io.open(Speed.path, "r")
        if not fh then return end
        local raw = fh:read("*a")
        fh:close()
        if not raw or raw == "" then return end
        local chunk = load(raw, "rotdurspeed", "t", {})
        if not chunk then return end
        local ok, val = pcall(chunk)
        if not ok or type(val) ~= "table" then return end
        local n = 0
        for k, v in pairs(val) do
            if type(v) == "table" and v.interval and Speed.map[k] == nil then
                Speed.map[k] = v
                n = n + 1
            end
        end
        if n > 0 then Log(string.format("loaded %d measured attack speeds", n)) end
    end)
end

function Speed.save()
    if not Speed.dirty or not Speed.path then return end
    Speed.dirty = false
    pcall(function()
        local keys = {}
        for k, e in pairs(Speed.map) do
            if not e.bundled then keys[#keys + 1] = k end
        end
        table.sort(keys)
        local fh = io.open(Speed.path, "w")
        if not fh then return end
        fh:write("-- RotDurability: attack cadence measured from real swings.\n")
        fh:write("-- interval is seconds between attacks. Safe to delete.\n")
        fh:write("return {\n")
        for _, k in ipairs(keys) do
            local e = Speed.map[k]
            fh:write(string.format(
                "  [%q] = { interval = %.4f, samples = %d, proj = %d, src = %q },\n",
                k, e.interval, e.samples or 0, e.proj or 1, e.src or "measured"))
        end
        fh:write("}\n")
        fh:close()
    end)
end

-- Hand-timed gaps are the weapon's cadence PLUS however long you hesitated,
-- and hesitation only ever runs one way - no one swings faster than the
-- animation allows. The gun calibration showed this exactly: a Nail Spitter
-- fires every 0.150s but hand-timing said 0.237s, while the slow Grain Splitter
-- (1.500 stated) hand-timed at 1.506 because there the player can keep up.
--
-- A median therefore sits above the truth and drifts with how deliberately you
-- were swinging - which is why an Iron Bonk read 0.690s one session and 0.741s
-- the next. The floor of the samples is the stable quantity. Not the outright
-- minimum, which one hitched frame could poison: the 25th percentile needs a
-- quarter of the swings to agree before it moves.
local function Floor(t)
    local c = {}
    for i = 1, #t do c[i] = t[i] end
    table.sort(c)
    local n = #c
    if n == 0 then return nil end
    local i = math.floor(n * CFG.SPEED_PERCENTILE + 0.5)
    if i < 1 then i = 1 end
    if i > n then i = n end
    return c[i]
end

-- Enum properties come back as a number on some builds and a wrapper on others.
local function EnumVal(v)
    local n = tonumber(v)
    if n then return n end
    local got
    pcall(function() got = v:get() end)
    return tonumber(got)
end

-- The weapon's display name, resolved once per actor instance. GetInspectData
-- is the same struct the panel shows, so its HeaderText is exactly the string
-- the panel will later use to look the cadence back up.
-- Identity is resolved by reading PROPERTIES, never by calling a UFunction.
--
-- This used to call actor:GetInspectData(). That is a UFunction invocation, and
-- LiveRangedSpec was making it ten times a second from inside the frame loop
-- for as long as an inspect panel was on screen. It crashed the game: a UE4SS
-- assert, "Abort signal received", with a callstack that was Lua re-entering
-- itself through the engine. Calling engine functions from inside a hook is the
-- known hazard here; reading a property is not. So: asset -> UniqueName -> the
-- friendly name already recorded beside that key.
local function WeaponName(actor)
    local asset
    pcall(function() asset = Unwrap(actor.ItemDataAsset) end)
    local key = AssetKeyOf(asset)
    if not key then return nil end
    local rec = Uses.map[key]
    if rec and rec.name and rec.name ~= "" then return rec.name end
    return key          -- unknown item: its own key is a stable enough handle
end

-- Dungeon loot that no shop sells has no path to UseDurabilityLoss, because the
-- buy widget is the only reflected surface that exposes it. But the weapon
-- spends that cost every time it is swung, so watching ItemDurability across
-- consecutive attacks measures it directly.
--
-- Deliberately strict: several consecutive drops must agree EXACTLY before the
-- value is accepted. A cost that varies between swings is not a per-use cost -
-- it is a continuous drain like the Rot Burner - and inventing a use count for
-- one of those is the mistake this mod already refused to make once.
local function LearnCostByUse(actor, name, loss, max)
    local asset
    pcall(function() asset = Unwrap(actor.ItemDataAsset) end)
    local key = AssetKeyOf(asset)
    if not key then return end

    local old = Uses.map[key]
    -- A shop reading is exact and a bundled one came from a shop; never
    -- overwrite either with something inferred from watching numbers move.
    if old and old.src ~= "measured" then return end
    if old and old.loss and math.abs(old.loss - loss) < 1e-6 then return end

    -- The hook has no panel to read a display name from, so WeaponName handed
    -- back the asset key. Flagging that as a placeholder is what lets the
    -- inspect panel correct it later, instead of the name-agreement guard
    -- rejecting a perfectly good cost because "Malet_01" is not "Mallet".
    Uses.map[key] = { loss = loss, name = name, src = "measured",
                      placeholder = (name == key) or nil,
                      max = (type(max) == "number" and max > 0) and max
                            or (old and old.max) or 0 }
    Uses.dirty = true
    S.learned = S.learned + 1
    Log(string.format("learned by use %s: %g durability per use, max %g (%s)",
        tostring(name), loss, Uses.map[key].max, key))
end

local function OnAttack(actor)
    if not IsLive(actor) then return end
    local inst = NameOf(actor)
    if inst == "?" then return end

    local rec = Actors[inst]
    if not rec then
        if nActors >= CFG.SPEED_MAX_ACTORS then Actors, nActors = {}, 0 end
        rec = { name = WeaponName(actor), last = nil, gaps = {}, deltas = {} }
        Actors[inst] = rec
        nActors = nActors + 1
    end
    if not rec.name then return end

    -- Durability first: it is read per attack regardless of whether the gap
    -- between attacks turns out to be usable for timing.
    if CFG.COST_BY_USE and rec.name then
        local dur, dmax
        pcall(function() dur = actor.ItemDurability end)
        pcall(function() dmax = actor.ItemDurabilityMax end)
        if type(dur) == "number" then
            if type(rec.lastDur) == "number" and rec.lastDur > dur then
                local d = rec.lastDur - dur
                if d > 0 and d <= CFG.COST_MAX_DELTA then
                    local dl = rec.deltas
                    dl[#dl + 1] = d
                    if #dl > CFG.COST_MIN_SAMPLES then table.remove(dl, 1) end
                    if #dl >= CFG.COST_MIN_SAMPLES then
                        local same = true
                        for i = 2, #dl do
                            if math.abs(dl[i] - dl[1]) > 0.001 then same = false break end
                        end
                        if same then LearnCostByUse(actor, rec.name, dl[1], dmax) end
                    end
                end
            end
            rec.lastDur = dur
        end
    end

    local now = os.clock()
    local prev = rec.last
    rec.last = now
    if not prev then return end

    local gap = now - prev
    -- Outside this band it is not a cadence: too short is one attack reported
    -- twice, too long is you having stopped swinging.
    if gap < CFG.SPEED_MIN_GAP or gap > CFG.SPEED_MAX_GAP then return end

    local g = rec.gaps
    g[#g + 1] = gap
    if #g == 1 then
        Log(string.format("timing %s (needs %d gaps, so %d attacks)",
            rec.name, CFG.SPEED_MIN_SAMPLES, CFG.SPEED_MIN_SAMPLES + 1))
    end
    if #g > CFG.SPEED_MAX_SAMPLES then table.remove(g, 1) end
    if #g < CFG.SPEED_MIN_SAMPLES then return end

    local med = Floor(g)
    if not med or med <= 0 then return end

    -- A ranged weapon states its own cooldown in FireRate, and that beats any
    -- measurement: verified against real fire, FireRate IS the seconds between
    -- shots (Grain Splitter 1.500 stated vs 1.506 measured, Scrap Blaster 1.000
    -- vs 1.008). Where the two diverge it is the PLAYER who is slow - a Nail
    -- Spitter can fire every 0.150s but hand-timed at 0.237s - so trusting the
    -- measurement there would report the trigger finger, not the weapon.
    local fr, np
    pcall(function() fr = actor.FireRate end)
    pcall(function() np = actor.NumProjectiles end)
    local iv, src = med, "measured"
    if type(fr) == "number" and fr > 0 then iv, src = fr, "firerate" end

    local old = Speed.map[rec.name]
    if old and old.bundled then old = nil end
    if old and old.src == "firerate" and src == "measured" then return end
    -- Converge downward and stay there. Since every sample overstates the
    -- cadence, a faster estimate is always the better one, and refusing to
    -- move back up is what stops the number wobbling between sessions.
    if old and src == "measured" and old.interval and iv > old.interval * 0.98 then
        return
    end
    if old and old.src == src and math.abs(old.interval - iv) < 0.005 then return end
    Speed.map[rec.name] = { interval = iv, samples = #g, src = src,
                            proj = (type(np) == "number" and np > 0) and np or 1 }
    Speed.dirty = true
    S.measured = S.measured + 1
    Log(string.format("%s %s: %.3fs between attacks (%.2f/s)%s",
        src == "firerate" and "cooldown" or "measured", rec.name, iv, 1 / iv,
        src == "firerate"
            and string.format(" [stated; hand-timed %.3fs]", med)
            or  string.format(" (%d samples)", #g)))

    -- FireRate is right there on ranged weapons but its unit is undocumented -
    -- shots per second and seconds per shot are both plausible. Logging it
    -- beside a measured interval says which, and a later version can then trust
    -- it directly and show DPS without needing to watch you fire first.
    if CFG.SPEED_CALIBRATE then
        local fr, np
        pcall(function() fr = actor.FireRate end)
        if fr == nil then pcall(function() fr = actor.AutoFireRate end) end
        pcall(function() np = actor.NumProjectiles end)
        if type(fr) == "number" and fr > 0 then
            Log(string.format("  calibrate %s: FireRate=%.4f measured=%.4fs " ..
                "(as-rate %.4fs, as-period %.4f/s) NumProjectiles=%s",
                rec.name, fr, med, 1 / fr, fr, tostring(np)))
        end
    end
end

-- Damage per hit, summed across every type the panel shows EXCEPT the two that
-- are not damage to an enemy: Construct (1) is Demolition Power, which only
-- applies to buildings, and Healing (4) is not damage at all. Percent-method
-- entries are a multiplier, not a flat amount, so they cannot join a sum.
local function DamagePerHit(widget)
    local total, pct = 0, 0
    local ok = pcall(function()
        local arr = widget.InspectData.TypedDamage
        if not arr then return end
        for i = 1, #arr do
            local e = arr[i]
            local ty, me = EnumVal(e.Type) or 0, EnumVal(e.Method) or 0
            if me == 1 then
                pct = pct + 1
            elseif ty ~= 1 and ty ~= 4 then
                local d = e.Damage
                if d and d.min and d.max then
                    total = total + (d.min + d.max) * 0.5
                end
            end
        end
    end)
    if not ok or total <= 0 then return nil, pct end
    return total, pct
end

-- --------------------------------------------------------------- tree walk

local function Walk(w, out, depth)
    if depth > CFG.WALK_DEPTH or not IsLive(w) then return end
    if #out > 64 then return end

    if ClassOf(w) == "TextBlock" then out[#out + 1] = w end

    local n
    pcall(function() n = w:GetChildrenCount() end)
    if type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local c
            pcall(function() c = w:GetChildAt(i) end)
            if c ~= nil then Walk(Unwrap(c), out, depth + 1) end
        end
    end

    local wt
    pcall(function() wt = w.WidgetTree end)
    if IsLive(wt) then
        local root
        pcall(function() root = wt.RootWidget end)
        if root ~= nil then Walk(Unwrap(root), out, depth + 1) end
    end
end

local function TextBlocksOf(widget)
    local out = {}
    local wt
    pcall(function() wt = widget.WidgetTree end)
    if IsLive(wt) then
        local root
        pcall(function() root = wt.RootWidget end)
        if root ~= nil then Walk(Unwrap(root), out, 0) end
    end
    return out
end

-- ------------------------------------------------------------- durability

-- Returns current, max - or nil when this panel is not an item panel.
local function ReadDurability(widget)
    local lo, hi
    pcall(function()
        local d = widget.InspectData.Durability
        if d ~= nil then lo, hi = d.min, d.max end
    end)
    if type(lo) ~= "number" or type(hi) ~= "number" then return nil end
    if hi <= 0 or lo < 0 or lo > hi then return nil end
    return lo, hi
end

-- Fallback identity: match on MaxDurability alone, and only when the answer is
-- unambiguous. Two items really do share a max while differing in per-use cost
-- (Grain Splitter and Scrap Blaster are both max 100), so a bare first-match
-- would confidently return the wrong lifespan. If the cache holds more than
-- one per-use cost for a given max, this gives up and the panel falls back to
-- points.
-- The panel we are about to write already names its own item in HeaderText,
-- and every cost we record carries the same display name. Matching those is
-- exact and needs nothing outside the panel - no actor, no durability
-- coincidence - so it is tried first.
local function LossForName(name)
    if type(name) ~= "string" or name == "" then return nil end
    -- Two passes: a cost measured on this machine outranks a bundled one. They
    -- can coexist under different keys for one weapon - a name-only default and
    -- the real UniqueName a shop later teaches - and the learned one is truth.
    for _, e in pairs(Uses.map) do
        if e.name == name and e.loss and not e.bundled then return e.loss end
    end
    for _, e in pairs(Uses.map) do
        if e.name == name and e.loss then return e.loss end
    end
    return nil
end

-- Exact identity. The content panel does not carry the item, but the info
-- widget alongside it does: UHeldenInspectInfoWidget.InspectData is an
-- FHeldenInspectTargetData, whose TargetActor is the thing being inspected
-- right now. From the actor, .ItemDataAsset is the same asset the shop handed
-- us as InAsset - so this closes the loop on the real key instead of guessing
-- from a number.
--
-- One info widget serves many content panels, so the actor is only trusted
-- when its own durability matches the panel we are about to write. That check
-- is what makes it safe to consult a single "current target" while refreshing
-- a registry that may still hold stale panels.
-- Superseded by LossForName and kept only for panels whose header is
-- unreadable. It now also refuses any actor whose recorded name disagrees
-- with the panel header: matching on durability alone identified the wrong
-- item whenever several nearby items sat at the same value, which is the
-- normal case in a shop where everything is untouched at 100 / 100.
local function ExactLossFor(cur, max, header)
    for _, e in pairs(S.infoWidgets) do
        if IsLive(e.w) then
            local actor
            pcall(function() actor = Unwrap(e.w.InspectData.TargetActor) end)
            if IsLive(actor) then
                local acur, amax
                pcall(function() acur = actor.ItemDurability end)
                pcall(function() amax = actor.ItemDurabilityMax end)
                if type(acur) == "number" and type(amax) == "number"
                   and math.abs(acur - cur) < 0.001 and math.abs(amax - max) < 0.001 then
                    local asset
                    pcall(function() asset = Unwrap(actor.ItemDataAsset) end)
                    local key = AssetKeyOf(asset)
                    local loss = Uses.lossFor(key)
                    local rec = key and Uses.map[key] or nil
                    -- A placeholder name is "unknown", not "different", so it
                    -- cannot disagree. This is also the one place where both
                    -- halves are in hand: the key that owns the cost, and the
                    -- header that names it. Take the name while we are here.
                    -- name == key also counts: entries written before the flag
                    -- existed carry the key as their name, and they need the
                    -- same correction rather than a cache wipe.
                    if rec and (rec.placeholder or rec.name == key)
                       and header and header ~= "" then
                        rec.name, rec.placeholder = header, nil
                        Uses.dirty = true
                        Log(string.format("named %s -> %q", key, header))
                    end
                    local agrees = not (header and header ~= "" and rec and rec.name
                                        and rec.name ~= header)
                    if loss and agrees then return loss end
                end
            end
        end
    end
    return nil
end

local function BuildLabel(cur, max, header)
    -- Lazily, so an inspect in the first seconds of a session still sees the
    -- bundled costs; the warmup call would not have run yet. Guarded inside.
    Uses.load()
    -- Name, then asset identity. There is deliberately no "guess from the
    -- maximum" fallback: it gave a Nail Spitter the Shredder cost of 1 purely
    -- because both hold 200 points, and a unique maximum is not identity.
    local loss = LossForName(header) or ExactLossFor(cur, max, header)
    if loss == nil and CFG.ASSUME_ONE_USE_PER_POINT then loss = 1.0 end

    local body
    if loss and loss > 0 then
        body = string.format("%d / %d uses",
            math.floor(cur / loss), math.floor(max / loss))
    else
        body = string.format("%d / %d", math.floor(cur + 0.5), math.floor(max + 0.5))
    end

    if CFG.SHOW_PERCENT then
        body = string.format("%s  %d%%", body, math.floor((cur / max) * 100 + 0.5))
    end
    return body
end

-- ------------------------------------------------------------ target pick

local function DumpPanel(entry)
    if not CFG.DIAG or entry.dumped or S.diag >= CFG.DIAG_MAX then return end
    entry.dumped = true
    S.diag = S.diag + 1

    local widget = entry.w
    local blocks = TextBlocksOf(widget)
    Log(string.format("panel %s: %d text blocks", ClassOf(widget), #blocks))
    for i, tb in ipairs(blocks) do
        Log(string.format("    [%d] %-24s %q", i, NameOf(tb), tostring(TextOf(tb))))
    end
end

-- Find the block currently showing the durability value.
--
-- Never by property name: Durability_label is the caption ("Durability:") and
-- the value lives in Health_Text, which no amount of reading the header dump
-- would have told us. What identifies the right block is that it is already
-- displaying the number we independently computed.
local function PickTarget(entry, cur, max, label)
    local widget = entry.w
    local want = math.floor((cur / max) * 100 + 0.5)
    local blocks = TextBlocksOf(widget)

    local hit, hits = nil, 0
    for _, tb in ipairs(blocks) do
        local s = TextOf(tb)
        -- Our own previous output counts as a match: a panel re-tracked under
        -- a changed full name has no percentage left on screen to recognise,
        -- and used to be abandoned with "no block reads N%".
        local mine = (s ~= nil and s == label)
        local p = AsPercent(s)
        local near = (p ~= nil and math.abs(p - want) <= CFG.PERCENT_SLOP)
        if mine or near then
            hits = hits + 1
            if not hit then hit = tb end
        end
    end

    if hit and hits == 1 then return hit, "matched" end
    if hit then return nil, string.format("ambiguous (%d blocks near %d%%)", hits, want) end
    return nil, string.format("no block reads %d%%", want)
end

-- ------------------------------------------------------------------ apply

-- The panel has no spare row, and building one at runtime is exactly the kind
-- of widget surgery this game crashes on, so the DPS rides along on the first
-- damage value already displayed. Idempotent by construction: our own suffix is
-- stripped before rewriting, so a re-render by the game cannot stack it up.
-- A ranged weapon carries its own cooldown and pellet count, so its DPS needs
-- no measuring pass at all - read them straight off the actor being inspected.
-- Same header-agreement guard as ExactLossFor: several untouched weapons lying
-- next to each other are indistinguishable by their numbers, only by name.
local function LiveRangedSpec(header)
    for _, e in pairs(S.infoWidgets) do
        if IsLive(e.w) then
            local actor
            pcall(function() actor = Unwrap(e.w.InspectData.TargetActor) end)
            if IsLive(actor) then
                -- Property read, not a UFunction call - see WeaponName.
                local asset
                pcall(function() asset = Unwrap(actor.ItemDataAsset) end)
                local akey = AssetKeyOf(asset)
                local arec = akey and Uses.map[akey] or nil
                local nm = arec and arec.name or nil
                if nm ~= nil and nm == header then
                    local fr, np
                    pcall(function() fr = actor.FireRate end)
                    pcall(function() np = actor.NumProjectiles end)
                    if type(fr) == "number" and fr > 0 then
                        return fr, (type(np) == "number" and np > 0) and np or 1
                    end
                    return nil
                end
            end
        end
    end
    return nil
end

local function ApplyDPS(entry, widget)
    if not CFG.SHOW_DPS then return end
    Speed.load()

    local header
    pcall(function() header = widget.InspectData.HeaderText:ToString() end)
    if type(header) ~= "string" or header == "" then return end

    local interval, proj = LiveRangedSpec(header)
    if interval then
        local old = Speed.map[header]
        if not old or old.src ~= "firerate" or old.proj ~= proj then
            Speed.map[header] = { interval = interval, samples = 0,
                                  proj = proj, src = "firerate" }
            Speed.dirty = true
        end
    else
        local sp = Speed.map[header]
        if not sp or not sp.interval or sp.interval <= 0 then return end
        interval, proj = sp.interval, sp.proj or 1
    end

    local dmg = DamagePerHit(widget)
    if not dmg then return end

    if not IsLive(entry.dmgTb) then
        for _, tb in ipairs(TextBlocksOf(widget)) do
            if NameOf(tb) == "Value_Text" then entry.dmgTb = tb break end
        end
        if not IsLive(entry.dmgTb) then return end
    end

    local shown = TextOf(entry.dmgTb)
    if type(shown) ~= "string" then return end
    local base = shown:match("^(.-)%s*x%d+%s*%(%d+ dps%)$")
              or shown:match("^(.-)%s*%(%d+ dps%)$")
              or shown
    -- The Scrap Blaster fires five pellets and its damage is quoted per pellet,
    -- so the x5 sits beside the range it multiplies. Folded silently into the
    -- DPS it would just look like the number was wrong.
    local mult = (proj > 1) and string.format(" x%d", proj) or ""
    local want = string.format("%s%s  (%d dps)", base, mult,
        math.floor(dmg * proj / interval + 0.5))
    if shown == want then return end
    pcall(function() entry.dmgTb:SetText(FText(want)) end)
end

local function Refresh(entry)
    local widget = entry.w
    if not IsLive(widget) then return false end

    -- Panels are built per inspect and linger until GC, so most of the
    -- registry is off-screen at any moment. Skip those: it is the difference
    -- between refreshing one panel and refreshing MAX_PANELS of them, 10x a
    -- second. A failed call falls through to refreshing, never to skipping.
    local vis
    pcall(function() vis = widget:IsVisible() end)
    if vis == false then return true end

    DumpPanel(entry)

    local cur, max = ReadDurability(widget)
    if not cur then return true end

    ApplyDPS(entry, widget)

    local header
    pcall(function() header = widget.InspectData.HeaderText:ToString() end)
    local label = BuildLabel(cur, max, header)

    if not IsLive(entry.tb) then
        local now = os.clock()
        if entry.nextPick and now < entry.nextPick then return true end
        entry.nextPick = now + CFG.PICK_RETRY_SECS

        local tb, why = PickTarget(entry, cur, max, label)
        if not tb then
            if entry.note ~= why then
                entry.note = why
                Log("give up on " .. ClassOf(widget) .. ": " .. why)
            end
            entry.last = label
            return true
        end
        entry.tb, entry.note = tb, nil
        -- A panel is built per inspect, so logging every bind is one line per
        -- item you look at. One confirmation per session is enough to show the
        -- mod found its target; the rest is DIAG.
        if CFG.DIAG or not S.everBound then
            S.everBound = true
            Log(string.format("bound %s -> %s (%s)", ClassOf(widget), NameOf(tb), why))
        end
    end

    local shown = TextOf(entry.tb)
    if shown == label then return true end

    -- Foreign content in a block we own: re-pick rather than fight over it.
    if shown ~= entry.last and shown ~= nil
       and AsPercent(shown) == nil and entry.last ~= nil then
        entry.tb, entry.nextPick = nil, nil
        return true
    end

    local ok = pcall(function() entry.tb:SetText(FText(label)) end)
    if not ok then
        Log("SetText failed on " .. ClassOf(widget) .. " - leaving the panel alone")
        entry.tb = nil
        entry.nextPick = os.clock() + 60
        return true
    end

    entry.last = label
    S.applied = S.applied + 1

    if not S.warnedDelegate and TextOf(entry.tb) ~= label then
        S.warnedDelegate = true
        Log("text reverted immediately - the block is a UMG binding, " ..
            "SetText alone will not hold")
    end
    return true
end

-- ------------------------------------------------------------------ intake

local function PruneOldest()
    if S.nPanels <= CFG.MAX_PANELS then return end
    local oldestKey, oldestSeq
    for k, e in pairs(S.panels) do
        if not oldestSeq or (e.seq or 0) < oldestSeq then
            oldestKey, oldestSeq = k, e.seq or 0
        end
    end
    if oldestKey then
        S.panels[oldestKey] = nil
        S.nPanels = S.nPanels - 1
    end
end

local function Track(obj)
    obj = Unwrap(obj)
    if not IsLive(obj) then return end
    local key
    pcall(function() key = tostring(obj:GetFullName()) end)
    if not key or S.panels[key] then return end
    S.seq = S.seq + 1
    S.panels[key] = { w = obj, seq = S.seq }
    S.nPanels = S.nPanels + 1
    PruneOldest()
    if CFG.DIAG then Log("tracking inspect panel: " .. ClassOf(obj)) end
end

-- The info widget is what knows WHICH actor is being inspected; the content
-- widget only knows the numbers. Tracked separately and never written to.
local function TrackInfo(obj)
    obj = Unwrap(obj)
    if not IsLive(obj) then return end
    local key
    pcall(function() key = tostring(obj:GetFullName()) end)
    if not key or S.infoWidgets[key] then return end
    S.infoWidgets[key] = { w = obj }
end

pcall(function()
    NotifyOnNewObject("/Script/Helden.HeldenInspectContentWidget", function(o) Track(o) end)
end)

pcall(function()
    NotifyOnNewObject("/Script/Helden.HeldenInspectInfoWidget", function(o) TrackInfo(o) end)
end)

-- The content sweep runs ONCE. It exists only to adopt panels that already
-- existed when this mod loaded; after that NotifyOnNewObject catches every new
-- one, and re-sweeping actively hurt: the registry cap evicts the oldest panel,
-- the next sweep re-adopts the very same still-alive widget, and the pair
-- thrash - which is what 16-bind bursts every 20s turned out to be.
local function CatchUpSweep(firstTime)
    if firstTime then
        pcall(function()
            local ws = FindAllOf("HeldenInspectContentWidget")
            if ws then for _, w in ipairs(ws) do Track(w) end end
        end)
    end
    pcall(function()
        local ws = FindAllOf("HeldenInspectInfoWidget")
        if ws then for _, w in ipairs(ws) do TrackInfo(w) end end
    end)
    -- Info widgets are few and long-lived, but drop any that died so the
    -- exact-identity scan stays short.
    for k, e in pairs(S.infoWidgets) do
        if not IsLive(e.w) then S.infoWidgets[k] = nil end
    end
end

-- ------------------------------------------------------------- shop probe
--
-- UHeldenBuyItemWidget::OnSetup(InAsset, InItem, InItemData) is the only place
-- the game hands out FHeldenItemData, so this is the only way to learn the
-- per-use cost. OnSetup is a BP event, so the UFunction that actually runs
-- belongs to the BP subclass - the class path is therefore read off a live
-- instance rather than guessed, and each distinct path is hooked once.

local function OnShopItem(InAsset, InItemData)
    local asset = Unwrap(InAsset)
    local data  = Unwrap(InItemData)
    if data == nil then return end

    local loss, max, name
    pcall(function() loss = data.UseDurabilityLoss end)
    pcall(function() max  = data.MaxDurability end)
    pcall(function() name = Str(data.FriendlyName) end)

    local key = AssetKeyOf(asset)
    if Uses.put(key, loss, max, name) then
        Uses.save()
        Speed.save()
        if CFG.PROBE_LOG then
            Log(string.format("learned %s: %.4g durability per use, max %.6g (%s)",
                tostring(name), loss or -1, max or -1, tostring(key)))
        end
    end
end

local function HookShopWidget(obj)
    if not CFG.PROBE_SHOP then return end
    obj = Unwrap(obj)
    if not IsLive(obj) then return end

    local path
    pcall(function()
        local full = obj:GetClass():GetFullName()   -- "Class /Game/..../X_C"
        if full then path = tostring(full):match("^%S+%s+(.+)$") end
    end)
    if not path or S.shopHooks[path] then return end
    S.shopHooks[path] = true

    local ok, err = pcall(function()
        RegisterHook(path .. ":OnSetup", function(self, InAsset, InItem, InItemData)
            pcall(OnShopItem, InAsset, InItemData)
        end)
    end)
    Log(ok and ("shop probe hooked " .. path)
           or ("shop probe failed on " .. path .. ": " .. tostring(err)))
end

pcall(function()
    NotifyOnNewObject("/Script/Helden.HeldenBuyItemWidget", function(o) HookShopWidget(o) end)
end)

-- ------------------------------------------------------------- frame driver

local function OnFrame()
    if S.errCount >= CFG.ERROR_CAP then return end
    S.frame = S.frame + 1
    local now = os.clock()

    if not S.sweepDone and S.frame >= CFG.SWEEP_WARMUP then
        S.sweepDone = true
        S.nextResweep = now + CFG.RESWEEP_SECS
        Uses.load()
        Speed.load()
        pcall(CatchUpSweep, true)
    elseif S.sweepDone and now >= S.nextResweep then
        S.nextResweep = now + CFG.RESWEEP_SECS
        pcall(CatchUpSweep, false)
    end

    if now < S.nextTick then return end
    S.nextTick = now + (1.0 / CFG.REFRESH_HZ)

    for key, entry in pairs(S.panels) do
        if S.errCount >= CFG.ERROR_CAP then break end   -- stop inside the loop
        local ok, err = pcall(Refresh, entry)
        if not ok then
            S.errCount = S.errCount + 1
            Log(string.format("refresh error (%d/%d): %s",
                S.errCount, CFG.ERROR_CAP, tostring(err)))
            if S.errCount >= CFG.ERROR_CAP then
                Log("error cap reached - RotDurability is now idle for this session")
            end
            S.panels[key] = nil
            S.nPanels = S.nPanels - 1
        elseif not IsLive(entry.w) then
            S.panels[key] = nil
            S.nPanels = S.nPanels - 1
        end
    end

    if (Speed.dirty or Uses.dirty) and now >= S.nextSpeedSave then
        S.nextSpeedSave = now + 10
        Speed.save()
        Uses.save()
    end

    if now >= S.nextStatus then
        S.nextStatus = now + 120
        local known = 0
        for _ in pairs(Uses.map) do known = known + 1 end
        Log(string.format("status: %d panels, %d rewrites, %d item costs known (%d new)",
            S.nPanels, S.applied, known, S.learned))
    end
end

local function EnsureHook()
    if S.hooked then return end
    local ok, err = pcall(function()
        RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
            function(self, DeltaTimeX) OnFrame() end)
    end)
    if ok then
        S.hooked = true
        Log("anim-update hook registered")
    else
        Log("hook registration failed (will retry on respawn): " .. tostring(err))
    end
end

EnsureHook()

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
        EnsureHook()
        -- ClientRestart fires during normal play too (elevator/repossession -
        -- MiniMap lesson), so this is a cheap soft reset: panels are rebuilt
        -- per inspect anyway, and the learned costs must survive.
        S.panels, S.nPanels = {}, 0
        S.infoWidgets = {}
        S.sweepDone = false
        Actors, nActors = {}, 0
    end)
end)

-- Attack_Multicast runs on every machine, so cadence is measured whether you
-- host or join, and for any weapon anyone swings. Per-actor bookkeeping keeps
-- two players holding the same weapon type from polluting each other.
pcall(function()
    RegisterHook("/Script/Helden.HeldenWeapon:Attack_Multicast", function(self)
        local ok = pcall(function() OnAttack(Unwrap(self)) end)
        if not ok then
            S.errCount = S.errCount + 1
            if S.errCount == CFG.ERROR_CAP then Log("attack hook erroring; muting") end
        end
    end)
    Log("attack-cadence hook registered")
end)

-- Ranged weapons never reach Attack_Multicast - AHeldenRangedWeapon has its own
-- fire path, which is why ten melee weapons measured and every gun stayed blank.
-- Fire_Multicast is one projectile, Multi_Fire_Multicast is a spread fired as a
-- single shot. Fire_Blank_Multicast is deliberately NOT hooked: that is the
-- empty click when a weapon has nothing left, not an attack, and counting it
-- would make a dead weapon look like it was firing fast.
for _, fn in ipairs({ "Fire_Multicast", "Multi_Fire_Multicast" }) do
    pcall(function()
        RegisterHook("/Script/Helden.HeldenRangedWeapon:" .. fn, function(self)
            pcall(function() OnAttack(Unwrap(self)) end)
        end)
        Log("ranged-fire hook registered: " .. fn)
    end)
end

Log(string.format("loaded v2.6 (uses%s, %dHz, dps=%s)",
    CFG.SHOW_PERCENT and " + percent" or "", CFG.REFRESH_HZ,
    tostring(CFG.SHOW_DPS)))
