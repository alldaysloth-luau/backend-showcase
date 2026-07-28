-- Master controller for tiles: state, smooth visuals, raycast ownership, effects
local TileController = {}

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Events = ServerStorage:WaitForChild("Events")
local LifeHit = Events:WaitForChild("LifeHit")

local TileVfxController = require(script:WaitForChild("TileVfxController"))
local TileTaxonomy = require(game.ServerStorage.Modules.TileTaxonomy)

local StateDurations = {
	Normal = 2.5,
	Charging = 1.5,
	Dangerous = 4.5,
	Recovering = 0.8,
}
local CycleSpeedMultiplier = 1

local TileDamage = 25
local RaycastDepth = 4

local PressureStartJitter = 0.35
local StandPressureTime = 0.85
local PressureRadius = 12
local PressureTiles = 4

local TilesPaused = false

local LuckyTileDangerousDuration = 10.0

local CycleRatioByRoom = {
	[1] = 0.70,
	[2] = 0.72,
	[3] = 0.78,
	[4] = 0.82,
	[5] = 0.90,
	[6] = 0.94,
	[7] = 0.97,
	[8] = 1.00,
	[9] = 1.00,
}

local DefaultCycleRatio = 1.00
local CycleMultiplier = 1

local MaxDangerousRatioByRoom = {
	[1] = 0.30,
	[2] = 0.32,
	[3] = 0.34,
	[4] = 0.41,
	[5] = 0.46,
	[6] = 0.50,
	[7] = 0.55,
	[8] = 0.60,
	[9] = 0.65,
	[10] = 0.70,
	[11] = 0.74,
	[12] = 0.78,
}
local DefaultMaxDangerousRatio = 0.85
local MaxDangerousMultiplier = 1

local HeatConfig = {
	AddPerSecond = 1.0,     -- heat gained per second while stood on (dt adds this)
	DecayPerSecond = 0.45,  -- heat lost per second when not being heated
	Trigger = 2.2,          -- when heat exceeds this, tile is forced into Charging
	Cooldown = 1.25,        -- prevents instantly re-triggering the same tile
	ForcedDuration = 1.25,  -- how long heat counts as "forced" similar to pressure
	StartJitter = 0.25,     -- small ripple feel
}

local MissingTileRatioByRoom = {
	[1] = 0.10,
	[2] = 0.18,
	[3] = 0.25,
	[4] = 0.30,
	[5] = 0.35,
}
local DefaultMissingTileRatio = 0.25

local DurationJitter = 0.45

local SafeColor = Color3.fromRGB(80, 255, 120)
local ChargingColor = Color3.fromRGB(255, 80, 80)
local DangerousColor = Color3.fromRGB(255, 0, 0)

local SafeTransparency = 1
local ChargingOnTransparency = 0.5
local ChargingOffTransparency = 0.6
local DangerousTransparency = 0.4

local ChargingFlashCount = 3
local VisualLerpSpeed = 14

local ChargeRumbleAmplitude = 0.11 -- studs
local ChargeRumbleFrequency = 18   -- Hz-ish

local AlwaysDangerousMin = 5
local AlwaysDangerousMax = 10

local ChargingQueue = {}
local ActiveTiles = {}
local PlayerCurrentTile = {}
local PlayerTileTime = {}
local Connections = {}

local TileVisualTargets = {}

local DangerousTiles = {}
local DangerousCount = 0
local TotalTileCount = 0
local MaxDangerousCount = 0
local ReservedDangerousSlots = 0

local EffectRuntime = {}

local RunStartTime = os.clock()
local TileOffsets = {} -- [Tile] = { BaseCFrame, Target, Current }
local PressDepth = 0.3 -- studs
local PressLerpSpeed = 14
local RoomProfile
local CurrentRoomFolder

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Include

local function GetGravityVector(): Vector3
	local v = workspace:GetAttribute("CurrentGravityVector")
	if typeof(v) == "Vector3" and v.Magnitude > 0.001 then
		return v
	end
	return Vector3.new(0, -1, 0)
end

local function GetActiveSurfaceFromGravity(Gravity: Vector3): string
	local g = Gravity.Unit

	local Axes = {
		Floor      = Vector3.new(0, -1, 0),
		Ceiling    = Vector3.new(0,  1, 0),
		WallRight  = Vector3.new( 1, 0, 0),
		WallLeft   = Vector3.new(-1, 0, 0),
		WallFront  = Vector3.new(0, 0, -1),
		WallBack   = Vector3.new(0, 0,  1),
	}

	local bestSurface = "Floor"
	local bestDot = -1

	for name, axis in pairs(Axes) do
		local d = g:Dot(axis)
		if d > bestDot then
			bestDot = d
			bestSurface = name
		end
	end

	return bestSurface
end

local CurrentActiveSurface = "Floor"

local function GetRoomIndexFromTiles(Tiles)
	for _, Tile in ipairs(Tiles) do
		local RoomIndex = Tile:GetAttribute("RoomIndex")
		if typeof(RoomIndex) == "number" then
			return RoomIndex
		end
	end
	return 1
end

local function GetCycleRatio(RoomIndex)
	return (CycleRatioByRoom[RoomIndex] or DefaultCycleRatio) * CycleMultiplier
end

local function GetMissingRatio(RoomIndex)
	return MissingTileRatioByRoom[RoomIndex] or DefaultMissingTileRatio
end

local function GetMaxDangerousRatio(RoomIndex)
	return MaxDangerousRatioByRoom[RoomIndex] or DefaultMaxDangerousRatio
end

local function TotalCycleDuration()
	return StateDurations.Normal
		+ StateDurations.Charging
		+ StateDurations.Dangerous
		+ StateDurations.Recovering
end

local function SetTilePhysicalVisible(Tile: Instance, Visible: boolean)
	if Tile:IsA("BasePart") then
		Tile.Transparency = Visible and 0 or 1
		Tile.CanCollide = Visible
		Tile.CanQuery = Visible
	end

	for _, d in ipairs(Tile:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Transparency = Visible and 0 or 1
			d.CanCollide = Visible
			d.CanQuery = Visible
		end
	end
	
	if not Visible then
		TileVfxController.SetAmbientEnabled(Tile, false)
	end
end

local function EnsureTileOffset(Tile)
	if not TileOffsets[Tile] then
		TileOffsets[Tile] = {
			BaseCFrame = Tile.CFrame,
			Target = 0,
			Current = 0,
		}
	end
	return TileOffsets[Tile]
end

local VisualController = {}
local BaseColors = {}

local function EnsureBaseColor(Tile)
	if not BaseColors[Tile] then
		if Tile:IsA("BasePart") then
			BaseColors[Tile] = Tile.Color
		else
			BaseColors[Tile] = Color3.new(1,1,1)
		end
	end
	return BaseColors[Tile]
end

local function ApplyColor(Tile, TargetColor, Alpha)
	if not Tile:IsA("BasePart") then return end
	local Base = EnsureBaseColor(Tile)
	Tile.Color = Base:Lerp(TargetColor, math.clamp(Alpha, 0, 1))
end

function VisualController.SetTarget(Tile, Enabled, Color, Alpha)
	TileVisualTargets[Tile] = TileVisualTargets[Tile] or {
		Enabled = true,
		Color = Color,
		Alpha = 0,
	}

	local T = TileVisualTargets[Tile]
	T.Enabled = Enabled
	if Color then T.Color = Color end
	if Alpha then T.Alpha = Alpha end
end

function VisualController.SetSafe(Tile)
	VisualController.SetTarget(Tile, true, SafeColor, 0.0)
end

function VisualController.SetDangerous(Tile)
	VisualController.SetTarget(Tile, true, DangerousColor, 1.0)
end

function VisualController.SetCharging(Tile, FlashOn)
	VisualController.SetTarget(
		Tile,
		true,
		ChargingColor,
		FlashOn and 0.85 or 0.55
	)
end

function VisualController.SetHidden(Tile)
	VisualController.SetTarget(Tile, false)
end

function VisualController.TickCharging(Tile, Elapsed, Duration)
	local p = math.clamp(Elapsed / math.max(Duration, 0.001), 0, 1)
	local seg = math.floor(p * ChargingFlashCount * 2)
	VisualController.SetCharging(Tile, seg % 2 == 0)
end

function VisualController.SetPressed(Tile, Pressed: boolean)
	if not Tile:IsA("BasePart") then return end
	local O = EnsureTileOffset(Tile)
	O.Target = Pressed and PressDepth or 0
	if Pressed and not Tile:FindFirstChildOfClass("Sound") then
		local Sound = game.ServerStorage.Assets.MoveStone:Clone()
		Sound.Parent = Tile
		Sound:Play()
		Sound.Ended:Connect(function()
			Sound:Destroy()
		end)
	end
end

function VisualController.Step(Tile, dt)
	if not Tile:IsA("BasePart") then return end

	local O = TileOffsets[Tile]
	if O then
		local a = 1 - math.exp(-PressLerpSpeed * dt)
		O.Current += (O.Target - O.Current) * a

		local Gravity = GetGravityVector().Unit
		local Down = Gravity

		local VisualOffset = Tile:GetAttribute("TileVisualOffset") or 0

		Tile.CFrame = O.BaseCFrame + Down * (O.Current + VisualOffset)
	end

	local Target = TileVisualTargets[Tile]
	if not Target then return end

	if not Target.Enabled then
		Tile.Color = EnsureBaseColor(Tile)
		return
	end

	local a = 1 - math.exp(-VisualLerpSpeed * dt)
	local Base = EnsureBaseColor(Tile)
	local Desired = Base:Lerp(Target.Color, Target.Alpha)
	Tile.Color = Tile.Color:Lerp(Desired, a)
end

function VisualController.ClearTile(Tile)
	BaseColors[Tile] = nil
	TileVisualTargets[Tile] = nil
end

function VisualController.ClearAll()
	for Tile in pairs(TileVisualTargets) do
		if Tile:IsA("BasePart") then
			Tile.Color = EnsureBaseColor(Tile)
		end
	end
	BaseColors = {}
	TileVisualTargets = {}
end

local EffectController = {}
local HitCooldown = 0.25

local function GetRuntime(Tile)
	local Runtime = EffectRuntime[Tile]
	if not Runtime then
		Runtime = {
			LastHitTime = 0,
			LastState = nil,
		}
		EffectRuntime[Tile] = Runtime
	end
	return Runtime
end

function EffectController.Apply(Tile, Humanoid)
	local Player = Players:GetPlayerFromCharacter(Humanoid.Parent)
	if not Player then return end
	
	local Runtime = GetRuntime(Tile)
	local Now = os.clock()

	if Now - Runtime.LastHitTime < HitCooldown then
		return
	end
	Runtime.LastHitTime = Now

	local TileType = Tile:GetAttribute("TileType")
	local TileCategory = Tile:GetAttribute("TileCategory")
	if TileType == "Neutral" then return end

	TileVfxController.HitEffect(Tile, Humanoid.Parent)

	--if TileType == "Void" then
	--	LifeHit:Fire(Player, 3)
	--	return
	--end
	
	if TileCategory ~= "Constraint" and TileCategory ~= "Movement" then
		LifeHit:Fire(Player, 1)
	end
end

function EffectController.OnStateChanged(Tile, OldState, NewState)
	TileVfxController.OnStateChanged(Tile, OldState, NewState)
end

local function GetDifficulty()
	return os.clock() - RunStartTime
end

local function GetDuration(Tile, State, RoomIndex)
	local Duration = StateDurations[State] / CycleSpeedMultiplier + (GetDifficulty() * 0.015)
	if not Duration then return 0 end

	-- Per-tile-type overrides (only when it's actually "active")
	if State == "Dangerous" then
		local TileType = Tile:GetAttribute("TileType")
		if TileType == "LuckyTile" then
			Duration = LuckyTileDangerousDuration
		end
	end

	local Factor = Tile:GetAttribute("DurationFactor")
	if typeof(Factor) == "number" then
		Duration *= Factor
	end

	return Duration
end

local function EnsureRumblePhase(Tile: Instance): number
	local Phase = Tile:GetAttribute("RumblePhase")
	if typeof(Phase) ~= "number" then
		Phase = math.random() * math.pi * 2
		Tile:SetAttribute("RumblePhase", Phase)
	end
	return Phase
end

local function SetTileVisualOffset(Tile: Instance, Offset: number)
	if (Tile:GetAttribute("TileVisualOffset") or 0) ~= Offset then
		Tile:SetAttribute("TileVisualOffset", Offset)
	end
end

local function ReleaseOldestDangerousTile()
	local Now = os.clock()
	local BestTile = nil
	local BestElapsed = -math.huge

	for Tile in pairs(DangerousTiles) do
		local StartTime = Tile:GetAttribute("StateStartTime")
		local State = Tile:GetAttribute("TileState")

		if State == "Dangerous" and StartTime then
			local Elapsed = Now - StartTime
			local Duration = GetDuration(Tile, "Dangerous", RoomProfile.RoomIndex)

			if Elapsed < Duration * 0.5 then
				continue
			end

			if Elapsed > BestElapsed then
				BestElapsed = Elapsed
				BestTile = Tile
			end
		end
	end

	if not BestTile then
		for Tile in pairs(DangerousTiles) do
			BestTile = Tile
			break
		end
	end

	if not BestTile then
		return
	end
	
	if DangerousTiles[BestTile] then
		DangerousTiles[BestTile] = nil
		DangerousCount -= 1
	end

	BestTile:SetAttribute("TileState", "Recovering")
	BestTile:SetAttribute("StateStartTime", Now)
end

local function RecountDangerous()
	local Count = 0

	for _, Tile in ipairs(ActiveTiles) do
		if Tile:GetAttribute("TileState") == "Dangerous" then
			Count += 1
			DangerousTiles[Tile] = true
		else
			DangerousTiles[Tile] = nil
		end
	end

	DangerousCount = Count
end

local function IsTileQueued(TargetTile)
	for i = 1, #ChargingQueue do
		if ChargingQueue[i] == TargetTile then
			return true
		end
	end
	return false
end

local function EnqueueChargingTile(TargetTile)
	if not IsTileQueued(TargetTile) then
		table.insert(ChargingQueue, TargetTile)
	end
end

local function PromoteQueuedTiles()
	local Now = os.clock()

	while DangerousCount < MaxDangerousCount do
		local BestIndex = nil
		local BestTile = nil
		local BestStartTime = math.huge

		for i = #ChargingQueue, 1, -1 do
			local Tile = ChargingQueue[i]

			if not Tile or not Tile.Parent then
				table.remove(ChargingQueue, i)
				continue
			end

			if Tile:GetAttribute("TileState") ~= "Charging" then
				table.remove(ChargingQueue, i)
				continue
			end

			local StartTime = Tile:GetAttribute("StateStartTime")
			local Duration = GetDuration(Tile, "Charging", RoomProfile.RoomIndex)

			if StartTime and (Now - StartTime) >= Duration then
				if StartTime < BestStartTime then
					BestStartTime = StartTime
					BestIndex = i
					BestTile = Tile
				end
			end
		end

		if not BestTile then
			break
		end

		table.remove(ChargingQueue, BestIndex)

		DangerousTiles[BestTile] = true
		DangerousCount += 1

		local NewType = TileTaxonomy.PickDangerousType
			and TileTaxonomy.PickDangerousType(BestTile, RoomProfile, CurrentRoomFolder:GetAttribute("PulseWave"))

		if NewType then
			for _, Def in ipairs(RoomProfile.AllowedTiles) do
				if Def.Name == NewType then
					TileController.ApplyTileMutation(BestTile, Def.Name, Def.Category)
					break
				end
			end
		end

		BestTile:SetAttribute("TileState", "Dangerous")
		BestTile:SetAttribute("StateStartTime", Now)

		DangerousTiles[BestTile] = true
		DangerousCount += 1
	end
end

local function UpdateTile(Tile, RoomIndex, Now, dt)
	-- Hard-missing
	if Tile:GetAttribute("IsMissing") then
		VisualController.SetHidden(Tile)
		TileVfxController.SetAmbientEnabled(Tile, false)
		return
	end

	local PulseWave = CurrentRoomFolder:GetAttribute("PulseWave") == true

	local TileSurface = Tile:GetAttribute("Surface")
	local IgnoreSurface = Tile:GetAttribute("IgnoreActiveSurface") == true
	local IsActiveSurface = (TileSurface == CurrentActiveSurface) or IgnoreSurface

	local State = Tile:GetAttribute("TileState")
	local Category = Tile:GetAttribute("TileCategory")
	local IsAlways = Tile:GetAttribute("AlwaysDangerous") == true

	-- Always-dangerous tiles
	if IsAlways then
		VisualController.SetDangerous(Tile)
		TileVfxController.SetAmbientEnabled(Tile, true)
		return
	end

	if not IsActiveSurface then
		VisualController.SetSafe(Tile)
		TileVfxController.SetAmbientEnabled(Tile, false)
		return
	end

	TileVfxController.SetAmbientEnabled(Tile, State == "Dangerous")

	local StartTime = Tile:GetAttribute("StateStartTime")
	if not State or not StartTime then
		return
	end
	
	local Heat = Tile:GetAttribute("Heat") or 0

	if Heat > 0 then
		Heat = math.max(0, Heat - HeatConfig.DecayPerSecond * dt)
		Tile:SetAttribute("Heat", Heat)
	end

	if Heat > HeatConfig.Trigger then
		Tile:SetAttribute("Heat", 0)

		if DangerousCount >= MaxDangerousCount then
			ReleaseOldestDangerousTile()
		end

		Tile:SetAttribute("TileState", "Charging")
		Tile:SetAttribute("StateStartTime", Now)
		EnqueueChargingTile(Tile)
	end

	local Runtime = GetRuntime(Tile)

	if Runtime.LastState ~= State then
		if Runtime.LastState ~= nil then
			EffectController.OnStateChanged(Tile, Runtime.LastState, State)
		end
		Runtime.LastState = State
	end

	local Elapsed = Now - StartTime
	local Duration = GetDuration(Tile, State, RoomIndex)

	-- Visuals
	if State == "Normal" then
		VisualController.SetSafe(Tile)
		SetTileVisualOffset(Tile, 0)
	elseif State == "Charging" then
		VisualController.TickCharging(Tile, Elapsed, Duration)

		local Phase = EnsureRumblePhase(Tile)
		local P = math.clamp(Elapsed / math.max(Duration, 0.001), 0, 1)
		local P2 = P * P
		local Amp = ChargeRumbleAmplitude * (0.25 + 0.75 * P2)

		local Freq = ChargeRumbleFrequency + (Phase * 0.15)
		local Offset = math.sin((Now * Freq) + Phase) * Amp

		SetTileVisualOffset(Tile, Offset)
	elseif State == "Dangerous" and Category == "Hazard" then
		VisualController.SetDangerous(Tile)
		SetTileVisualOffset(Tile, 0)
	else
		VisualController.SetSafe(Tile)
	end

	-- During PulseWave the RuleController owns the state machine
	if PulseWave then
		if State ~= "Dangerous" then
			if DangerousTiles[Tile] then
				DangerousTiles[Tile] = nil
				DangerousCount -= 1
			end
		end
		return
	end

	if Duration <= 0 then
		return
	end

	if Elapsed < Duration then
		return
	end

	if State == "Normal" then
		if DangerousCount + #ChargingQueue < MaxDangerousCount then
			Tile:SetAttribute("TileState", "Charging")
			Tile:SetAttribute("StateStartTime", Now)
			EnqueueChargingTile(Tile)
		end
		return
	end

	if State == "Charging" then
		return
	end

	if State == "Dangerous" then
		if DangerousTiles[Tile] then
			DangerousTiles[Tile] = nil
			DangerousCount -= 1
		end

		Tile:SetAttribute("TileState", "Recovering")
		Tile:SetAttribute("StateStartTime", Now)
		return
	end

	if State == "Recovering" then
		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("StateStartTime", Now)
	end
end

local function GetNeighborTiles(CenterTile, Tiles)
	local CenterX = CenterTile:GetAttribute("GridX")
	local CenterY = CenterTile:GetAttribute("GridY")
	local Surface = CenterTile:GetAttribute("Surface")

	local NeighborTiles = {CenterTile}

	for _, Tile in ipairs(Tiles) do
		if Tile:GetAttribute("Surface") ~= Surface then
			continue
		end

		local X = Tile:GetAttribute("GridX")
		local Y = Tile:GetAttribute("GridY")
		
		local DX = math.abs(X - CenterX)
		local DY = math.abs(Y - CenterY)

		if DX == 0 and DY == 0 then
			continue
		end

		if DX <= 1 and DY <= 1 then
			table.insert(NeighborTiles, Tile)
		end
	end

	return NeighborTiles
end

TileController.GetNeighborTiles = GetNeighborTiles

local function ApplyLocalPressure(Player)
	local CenterTile = PlayerCurrentTile[Player]
	if not CenterTile then return end

	local TilesToPressure = GetNeighborTiles(CenterTile, ActiveTiles)

	for _, Tile in ipairs(TilesToPressure) do
		if Tile:GetAttribute("IsMissing") then
			continue
		end

		if not Tile:GetAttribute("PressureEnabled") then
			continue
		end

		local State = Tile:GetAttribute("TileState")

		if State == "Dangerous" or State == "Charging" then
			continue
		end

		if DangerousCount >= MaxDangerousCount then
			ReleaseOldestDangerousTile()
		end

		Tile:SetAttribute("PressureForcedUntil", os.clock() + 1.5)
		
		if DangerousCount + #ChargingQueue < MaxDangerousCount then
			Tile:SetAttribute("TileState", "Charging")

			local Jitter = (math.random() * 2 - 1) * PressureStartJitter
			Tile:SetAttribute("StateStartTime", os.clock() + Jitter)

			EnqueueChargingTile(Tile)
		end
	end
end

local function ResolveTileFromInstance(Inst)
	while Inst do
		if Inst:GetAttribute("TileState") ~= nil then
			return Inst
		end
		Inst = Inst.Parent
	end
	return nil
end

local function UpdatePlayerTile(Player)
	local Character = Player.Character
	if not Character then return end

	local Root = Character:FindFirstChild("HumanoidRootPart")
	if not Root then return end

	local Down = -Root.CFrame.UpVector
	local HalfSize = Root.Size * 0.45

	local CastCFrame = Root.CFrame
	local CastSize = Vector3.new(
		HalfSize.X,
		0.6,
		HalfSize.Z
	)

	local Result = workspace:Blockcast(
		CastCFrame,
		CastSize,
		Down * RaycastDepth,
		RayParams
	)
	
	local NewTile = nil

	if Result then
		NewTile = ResolveTileFromInstance(Result.Instance)
	end

	local OldTile = PlayerCurrentTile[Player]
	if NewTile ~= OldTile then
		PlayerCurrentTile[Player] = NewTile
		PlayerTileTime[Player] = 0
	end
end

local function UpdatePlayers(dt)
	for _, T in ipairs(ActiveTiles) do
		VisualController.SetPressed(T, false)
	end

	local PulseWave = CurrentRoomFolder:GetAttribute("PulseWave") == true

	for _, Player in ipairs(Players:GetPlayers()) do
		UpdatePlayerTile(Player)

		local Tile = PlayerCurrentTile[Player]
		if Tile then
			VisualController.SetPressed(Tile, true)

			if Tile:GetAttribute("Surface") ~= CurrentActiveSurface then
				continue
			end

			if not PulseWave then
				PlayerTileTime[Player] = (PlayerTileTime[Player] or 0) + dt

				if PlayerTileTime[Player] > StandPressureTime then
					ApplyLocalPressure(Player)
				end

				local Heat = Tile:GetAttribute("Heat") or 0
				Tile:SetAttribute("Heat", Heat + HeatConfig.AddPerSecond * dt)
			end

			local IsAlways = Tile:GetAttribute("AlwaysDangerous") == true
			local IsActiveSurface = Tile:GetAttribute("Surface") == CurrentActiveSurface

			if Tile:GetAttribute("IsMissing") then continue end
			local State = Tile:GetAttribute("TileState")

			if State ~= "Dangerous" then
				if Tile:GetAttribute("CycleEnabled") == false and not Tile:GetAttribute("RuleForced") then
					continue
				end
			end

			if Tile:GetAttribute("TileState") == "Dangerous"
				and (IsActiveSurface or IsAlways)
			then
				local Character = Player.Character
				local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")

				if Humanoid then
					EffectController.Apply(Tile, Humanoid)
				end
			end
		end
	end
end

local function SeedTileCycleState(Tile, RoomIndex, Now)
	-- If not cycling, start cleanly in Normal
	if Tile:GetAttribute("CycleEnabled") == false then
		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("StateStartTime", Now)
		return
	end

	local dN = GetDuration(Tile, "Normal", RoomIndex)
	local dC = GetDuration(Tile, "Charging", RoomIndex)
	local dD = GetDuration(Tile, "Dangerous", RoomIndex)
	local dR = GetDuration(Tile, "Recovering", RoomIndex)
	local Total = dN + dC + dD + dR
	if Total <= 0 then
		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("StateStartTime", Now)
		return
	end

	local roll = math.random()

	local State
	local IntoState

	if roll < 0.70 then
		State = "Normal"
		IntoState = math.random() * dN
	elseif roll < 0.95 then
		State = "Charging"
		IntoState = math.random() * dC
	else
		State = "Recovering"
		IntoState = math.random() * dR
	end
	
	-- Respect global cap at seed-time to avoid starting with a spike
	if State == "Dangerous"
		and Tile:GetAttribute("TileCategory") == "Hazard"
		and Tile:GetAttribute("AlwaysDangerous") ~= true
	then
		if DangerousCount >= MaxDangerousCount then
			State = "Charging"
			IntoState = math.min(IntoState, math.max(dC - 0.1, 0))
		else
			if not DangerousTiles[Tile] then
				DangerousTiles[Tile] = true
				DangerousCount += 1
			end
		end
	end

	Tile:SetAttribute("TileState", State)
	Tile:SetAttribute("StateStartTime", Now - IntoState)

	if State == "Charging" then
		EnqueueChargingTile(Tile)
	end
end

local function NudgeSurfaceCycles(Surface)
	for _, Tile in ipairs(ActiveTiles) do
		if Tile:GetAttribute("Surface") ~= Surface then
			continue
		end

		if Tile:GetAttribute("IsMissing") then
			continue
		end

		if Tile:GetAttribute("AlwaysDangerous") then
			continue
		end

		local State = Tile:GetAttribute("TileState")

		if State == "Normal" then
			if math.random() < 0.35 then
				Tile:SetAttribute("TileState","Charging")
				Tile:SetAttribute("StateStartTime",os.clock())
				EnqueueChargingTile(Tile)
			end
		end
	end
end

function TileController.RegisterTiles(Tiles, GameMode, SpeedrunDifficultyRoom, CurrentRoomProfile, RoomFolder)
	TileController.Clear()
	RoomFolder:SetAttribute("PulseWave", false)
	
	RunStartTime = os.clock()
	ActiveTiles = Tiles
	CurrentRoomFolder = RoomFolder

	RayParams.FilterDescendantsInstances = Tiles

	local LogicalRoomIndex = GetRoomIndexFromTiles(Tiles)
	local DifficultyRoomIndex =
		GameMode == "Speedrun"
		and SpeedrunDifficultyRoom
		or LogicalRoomIndex

	local CycleRatio = GetCycleRatio(DifficultyRoomIndex)
	local MissingRatio = GetMissingRatio(DifficultyRoomIndex)
	
	RoomProfile = CurrentRoomProfile

	local RealTileCount = 0

	for _, Tile in ipairs(Tiles) do
		if Tile:GetAttribute("IsBoundary") then continue end
		if Tile:GetAttribute("IsMissing") then continue end
		RealTileCount += 1
	end

	local ActiveCycleCount = math.floor(RealTileCount * CycleRatio)
	warn(RealTileCount)

	local NewMax =
		math.floor(
			math.floor(ActiveCycleCount * GetMaxDangerousRatio(DifficultyRoomIndex))
			* MaxDangerousMultiplier
		)

	MaxDangerousCount = math.max(1, NewMax)
	DangerousTiles = {}
	DangerousCount = 0
	ChargingQueue = {}

	local TotalCycle = TotalCycleDuration()

	for _, Tile in ipairs(Tiles) do
		EnsureTileOffset(Tile)
		Tile:SetAttribute("AlwaysDangerous", false)
		Tile:SetAttribute("TileVisualOffset", 0)
		Tile:SetAttribute("RuleForced", nil)

		if Tile:GetAttribute("IsBoundary") then
			Tile:SetAttribute("IsMissing", false)
			Tile:SetAttribute("CycleEnabled", false)
			Tile:SetAttribute("TileState", "Normal")

			if Tile:IsA("BasePart") then
				Tile.Transparency = 0
				Tile.CanCollide = true
			end

			VisualController.SetHidden(Tile)
			TileVfxController.SetAmbientEnabled(Tile, false)
			continue
		end

		local IsMissing = math.random() < MissingRatio
		Tile:SetAttribute("IsMissing", IsMissing)

		if IsMissing then
			SetTilePhysicalVisible(Tile, false)
			VisualController.SetHidden(Tile)
			TileVfxController.SetAmbientEnabled(Tile, false)
			continue
		end

		-- Restore tile if previously missing
		SetTilePhysicalVisible(Tile, true)

		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("CycleEnabled", math.random() < CycleRatio)
		Tile:SetAttribute("PressureEnabled", true)
		Tile:SetAttribute("DurationFactor", 1 + ((math.random() * 2 - 1) * DurationJitter))
		
		Tile:SetAttribute("Heat", 0)
		Tile:SetAttribute("HeatCooldownUntil", 0)

		-- local Offset = Tile:GetAttribute("CycleEnabled") and math.random() * TotalCycle or 0
		-- Tile:SetAttribute("StateStartTime", os.clock() - Offset)

		local Now = os.clock()
		SeedTileCycleState(Tile, DifficultyRoomIndex, Now)

		EffectRuntime[Tile] = nil
		VisualController.SetSafe(Tile)
	end
	
	while DangerousCount > MaxDangerousCount do
		ReleaseOldestDangerousTile()
	end

	local TilesBySurface = {}

	for _, Tile in ipairs(Tiles) do
		if Tile:GetAttribute("IsMissing") then continue end
		if Tile:GetAttribute("IsBoundary") then continue end
		if Tile:GetAttribute("TileCategory") ~= "Hazard" then continue end

		local Surface = Tile:GetAttribute("Surface")
		TilesBySurface[Surface] = TilesBySurface[Surface] or {}
		table.insert(TilesBySurface[Surface], Tile)
	end

	local ActiveSurface = CurrentActiveSurface
	local SurfaceTiles = TilesBySurface[ActiveSurface]

	if SurfaceTiles and #SurfaceTiles > 0 then
		local RemainingSlots = math.max(0, MaxDangerousCount - DangerousCount)

		local Count = math.clamp(
			math.random(AlwaysDangerousMin, AlwaysDangerousMax),
			0,
			math.min(#SurfaceTiles, RemainingSlots)
		)

		for i = 1, Count do
			local Index = math.random(#SurfaceTiles)
			local Tile = table.remove(SurfaceTiles, Index)

			Tile:SetAttribute("AlwaysDangerous", true)
			Tile:SetAttribute("TileState", "Dangerous")
			Tile:SetAttribute("CycleEnabled", false)

			if not DangerousTiles[Tile] then
				DangerousTiles[Tile] = true
				DangerousCount += 1
			end

			VisualController.SetDangerous(Tile)
		end
	end

	local SyncTimer = 0
	Connections.Update = RunService.Heartbeat:Connect(function(dt)
		if TilesPaused then
			return
		end
		
		local NewSurface = GetActiveSurfaceFromGravity(GetGravityVector())

		if NewSurface ~= CurrentActiveSurface then
			TileTaxonomy.InheritSurfaceHistory(RoomProfile, CurrentActiveSurface, NewSurface)
			CurrentActiveSurface = NewSurface
			
			NudgeSurfaceCycles(CurrentActiveSurface)
		end

		PromoteQueuedTiles()

		local NowTime = os.clock()

		for _, Tile in ipairs(ActiveTiles) do
			UpdateTile(Tile, DifficultyRoomIndex, NowTime, dt)
			VisualController.Step(Tile, dt)
		end

		UpdatePlayers(dt)
		
		SyncTimer = (SyncTimer or 0) + dt
		if SyncTimer > 2 then
			SyncTimer = 0
			RecountDangerous()
		end
	end)
end

function TileController.Clear()
	for _, C in pairs(Connections) do
		C:Disconnect()
	end
	RoomProfile = nil
	Connections = {}
	ActiveTiles = {}
	PlayerCurrentTile = {}
	PlayerTileTime = {}
	ChargingQueue = {}
	TileVisualTargets = {}
	DangerousTiles = {}
	DangerousCount = 0
	EffectRuntime = {}
	TileVfxController.ClearAll()
end

function TileController.ForceAllTilesNormal()
	DangerousTiles = {}
	DangerousCount = 0

	for _, Tile in ipairs(ActiveTiles) do
		if not Tile:IsA("BasePart") then
			continue
		end

		Tile:SetAttribute("AlwaysDangerous", false)
		Tile:SetAttribute("IsMissing", false)

		Tile:SetAttribute("CycleEnabled", false)
		Tile:SetAttribute("PressureEnabled", false)
		Tile:SetAttribute("RuleForced", true)

		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("StateStartTime", os.clock())

		Tile:SetAttribute("Heat", 0)
		Tile:SetAttribute("HeatCooldownUntil", 0)
		Tile:SetAttribute("PressureForcedUntil", nil)

		Tile:SetAttribute("TileVisualOffset", 0)

		SetTilePhysicalVisible(Tile, true)

		TileVfxController.SetAmbientEnabled(Tile, false)

		local Offset = EnsureTileOffset(Tile)
		Offset.Target = 0
		Offset.Current = 0

		VisualController.SetSafe(Tile)
	end
end

function TileController.ResetTile(Tile)
	if not Tile:IsA("BasePart") then return end

	Tile:SetAttribute("IgnoreActiveSurface", nil)
	Tile:SetAttribute("RuleForced", nil)
	Tile:SetAttribute("AlwaysDangerous", false)

	Tile:SetAttribute("IsMissing", false)
	Tile:SetAttribute("CycleEnabled", true)
	Tile:SetAttribute("PressureEnabled", true)

	Tile:SetAttribute("TileState", "Normal")
	Tile:SetAttribute("StateStartTime", os.clock())

	Tile:SetAttribute("Heat", 0)
	Tile:SetAttribute("HeatCooldownUntil", 0)
	Tile:SetAttribute("PressureForcedUntil", nil)

	Tile:SetAttribute("TileVisualOffset", 0)

	TileVfxController.ClearTile(Tile)

	Tile.Transparency = 0
	Tile.CanCollide = true
	Tile.CanQuery = true
end

function TileController.RecomputeDangerousCap(RoomIndex, Multiplier)
	Multiplier = Multiplier or 1
	local RealTileCount = 0
	local AlwaysDangerousCount = 0

	for _, Tile in ipairs(ActiveTiles) do
		if Tile:GetAttribute("IsBoundary") then continue end
		if Tile:GetAttribute("IsMissing") then continue end

		RealTileCount += 1

		if Tile:GetAttribute("AlwaysDangerous") then
			AlwaysDangerousCount += 1
		end
	end

	local CycleRatio = GetCycleRatio(RoomIndex)
	local ActiveCycleCount = math.floor(RealTileCount * CycleRatio)

	local NewMax =
		math.floor(
			math.floor(ActiveCycleCount * GetMaxDangerousRatio(RoomIndex))
			* MaxDangerousMultiplier
		)

	MaxDangerousCount = math.max(1, math.floor(NewMax * Multiplier))
	local DynamicCap = math.max(0, MaxDangerousCount - AlwaysDangerousCount)

	while DangerousCount > (DynamicCap + AlwaysDangerousCount) do
		ReleaseOldestDangerousTile()
	end
end

function TileController.ApplyTileMutation(Tile, NewType, NewCategory)
	local OldType = Tile:GetAttribute("TileType")
	local OldCategory = Tile:GetAttribute("TileCategory")
	
	if DangerousTiles[Tile] then
		DangerousTiles[Tile] = nil
		DangerousCount -= 1
	end
	
	for i = #ChargingQueue, 1, -1 do
		if ChargingQueue[i] == Tile then
			table.remove(ChargingQueue, i)
		end
	end

	Tile:SetAttribute("TileType", NewType)
	Tile:SetAttribute("TileCategory", NewCategory)

	Tile:SetAttribute("TileState", "Normal")
	Tile:SetAttribute("StateStartTime", os.clock())

	Tile:SetAttribute("Heat", 0)
	Tile:SetAttribute("PressureForcedUntil", nil)
	Tile:SetAttribute("HeatCooldownUntil", 0)

	Tile:SetAttribute("AlwaysDangerous", false)
	
	EffectRuntime[Tile] = nil

	VisualController.SetSafe(Tile)
	SetTileVisualOffset(Tile, 0)
	
	if TileTaxonomy and RoomProfile then
		TileTaxonomy.RegisterPlacedTile(RoomProfile, Tile, NewType, NewCategory)
	end
end

function TileController.ApplyMaxDangerousMultiplier(Multiplier)
	MaxDangerousMultiplier = Multiplier
end

function TileController.SetCycleMultiplier(Multiplier)
	CycleMultiplier = Multiplier
end

function TileController.SetCycleSpeed(Multiplier)
	CycleSpeedMultiplier = Multiplier
end

function TileController.SetPaused(State: boolean)
	TilesPaused = State
end

function TileController.IsPaused()
	return TilesPaused
end

return TileController
