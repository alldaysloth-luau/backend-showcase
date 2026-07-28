-- Manages enabling, disabling, and applying room rules
local RuleController = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ServerStorage = game:GetService("ServerStorage")
local GravityController = require(script:WaitForChild("GravityController"))
local TileController = require(ServerStorage:WaitForChild("Modules"):WaitForChild("TileController"))

local StillnessSpeedThreshold = 2.5 -- studs/s considered "not moving"
local StillnessGraceTime = 1.1 -- seconds before punishment starts
local StillnessDamagePerSecond = 12

local GravityForceMultiplier_Low = 0.65 -- reduces effective gravity
local GravityForceMultiplier_Reverse = 1.15 -- reverse gravity strength
local GravityForceMultiplier_Omni = 1.35 -- pull strength toward center

local MomentumAssistStrength = 0.55
local MomentumMaxAssistSpeed = 80

local TimeElasticMinScale = 0.75
local TimeElasticMaxScale = 1.25

export type RuleContext = {
	World: Instance,
	Tiles: { Instance },
	RoomIndex: number?,
}

type RuleRuntimeState = {
	Name: string,
	Connections: { RBXScriptConnection },
	Instances: { Instance },
	Data: { [string]: any },
	Context: RuleContext?,
	Cleanup: ((RuleContext) -> ())?,
}

type RuleDefinition = {
	Name: string,
	MinRoom: number,
	Apply: (RuleContext) -> RuleRuntimeState,
}

local ActiveRuleStates: { RuleRuntimeState } = {}

local function GetRoomBounds(World: Instance): (Vector3, Vector3)
	if World:IsA("Model") then
		local CFrameValue, SizeValue = World:GetBoundingBox()
		return CFrameValue.Position, SizeValue
	end

	local BoundsPart = World:FindFirstChild("Bounds")
	if BoundsPart and BoundsPart:IsA("BasePart") then
		return BoundsPart.Position, BoundsPart.Size
	end

	return Vector3.new(0, 0, 0), Vector3.new(10_000, 10_000, 10_000)
end

local function IsPositionInBounds(Position: Vector3, Center: Vector3, Size: Vector3): boolean
	local Half = Size * 0.5
	return (Position.X >= Center.X - Half.X and Position.X <= Center.X + Half.X)
		and (Position.Y >= Center.Y - Half.Y and Position.Y <= Center.Y + Half.Y)
		and (Position.Z >= Center.Z - Half.Z and Position.Z <= Center.Z + Half.Z)
end

local function GetCharacterRoot(Character: Model): BasePart?
	return Character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function GetHumanoid(Character: Model): Humanoid?
	return Character:FindFirstChildOfClass("Humanoid")
end

local function IsCharacterInRoom(Character: Model, RoomCenter: Vector3, RoomSize: Vector3): boolean
	local RootPart = GetCharacterRoot(Character)
	if not RootPart then
		return false
	end
	return IsPositionInBounds(RootPart.Position, RoomCenter, RoomSize)
end

local function EnsureAttachment(Part: BasePart, Name: string): Attachment
	local Existing = Part:FindFirstChild(Name)
	if Existing and Existing:IsA("Attachment") then
		return Existing
	end

	local NewAttachment = Instance.new("Attachment")
	NewAttachment.Name = Name
	NewAttachment.Parent = Part
	return NewAttachment
end

local function CreateVectorForce(RootPart: BasePart, Name: string): VectorForce
	local Attachment = EnsureAttachment(RootPart, Name .. "_Attachment")

	local Force = Instance.new("VectorForce")
	Force.Name = Name
	Force.ApplyAtCenterOfMass = true
	Force.RelativeTo = Enum.ActuatorRelativeTo.World
	Force.Attachment0 = Attachment
	Force.Force = Vector3.zero
	Force.Parent = RootPart

	return Force
end

local function CreateLinearVelocity(RootPart: BasePart, Name: string): LinearVelocity
	local Attachment = EnsureAttachment(RootPart, Name .. "_Attachment")

	local Vel = Instance.new("LinearVelocity")
	Vel.Name = Name
	Vel.Attachment0 = Attachment
	Vel.RelativeTo = Enum.ActuatorRelativeTo.World
	Vel.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	Vel.VectorVelocity = Vector3.zero
	Vel.MaxForce = math.huge
	Vel.Parent = RootPart

	return Vel
end

local function UpdateRoomShellCollision(World: Instance, GravityDir: Vector3)
	local SurfaceForGravity = {
		["0_-1_0"] = "Floor",
		["0_1_0"] = "Ceiling",
		["0_0_1"] = "WallBack",
		["-1_0_0"] = "WallLeft",
	}

	local Key = string.format("%d_%d_%d", GravityDir.X, GravityDir.Y, GravityDir.Z)
	local WalkSurface = SurfaceForGravity[Key]

	for _, Desc in ipairs(World:GetChildren()) do
		if not Desc:IsA("BasePart") then
			continue
		end

		local Surface = Desc:GetAttribute("Border")
		if not Surface then
			continue
		end

		if Surface == WalkSurface then
			Desc.CanCollide = false
		else
			Desc.CanCollide = true
		end
	end
end

GravityController.SetGravity(Vector3.new(0, -1, 0), 5)
GravityController.Enable()

local function ApplyGravityRule(Context: RuleContext): RuleRuntimeState
	local RoomCenter, RoomSize = GetRoomBounds(Context.World)

	-- Logical / authoritative gravity directions
	local GravityVectors = {
		Normal  = Vector3.new(0, -1, 0),
		Reverse = Vector3.new(0,  1, 0),
		Left    = Vector3.new(0,  0, 1),
		Right   = Vector3.new(-1, 0, 0),
	}

	local ModeNames

	if (Context.RoomIndex or 1) > 6 then
		ModeNames = { "Normal", "Reverse", "Left", "Right", "Chaos" }
	else
		ModeNames = { "Normal", "Reverse", "Left", "Right" }
	end
	local Mode = ModeNames[math.random(1, #ModeNames)]

	local LogicalDir
	if Mode ~= "Chaos" then
		LogicalDir = GravityVectors[Mode]
	else
		local Keys = { "Normal", "Reverse", "Left", "Right" }
		local Pick = Keys[math.random(#Keys)]
		LogicalDir = GravityVectors[Pick]
	end

	Context.World:SetAttribute("GravityMode", Mode)
	Context.World:SetAttribute("GravityDirection", LogicalDir)

	GravityController.SetGravity(LogicalDir, 5)
	UpdateRoomShellCollision(Context.World, LogicalDir)

	if Mode == "Chaos" then
		game.SoundService.Gravity_SFX:Play()
	end

	local RuntimeState: RuleRuntimeState = {
		Name = "Gravity",
		Connections = {},
		Instances = {},
		Data = {
			Mode = Mode,
			RoomCenter = RoomCenter,
			RoomSize = RoomSize,
			CurrentDir = LogicalDir
		},
		Cleanup = function(CleanupContext: RuleContext)
			-- Reset to default gravity deterministically
			CleanupContext.World:SetAttribute("GravityMode", "Normal")
			CleanupContext.World:SetAttribute("GravityDirection", Vector3.new(0, -1, 0))

			GravityController.SetGravity(Vector3.new(0, -1, 0), 5)
			UpdateRoomShellCollision(CleanupContext.World, Vector3.new(0, -1, 0))
			game.SoundService.Gravity_SFX:Play()
		end,
	}

	if Mode == "Chaos" then
		local FlipInterval = 5
		local Elapsed = 0

		local PlayedSound = false

		local Connection
		Connection = RunService.Heartbeat:Connect(function(dt)
			Elapsed += dt
			if Elapsed >= 4 and not PlayedSound then
				PlayedSound = true
				game.SoundService.GravitySwitch_SFX:Play()
			end
			
			if Elapsed < FlipInterval then
				return
			end

			Elapsed = 0
			PlayedSound = false

			local CurrentDir = Context.World:GetAttribute("GravityDirection")

			local Keys = {"Normal", "Reverse", "Left", "Right"}
			local Pick
			local Dir

			repeat
				Pick = Keys[math.random(#Keys)]
				Dir = GravityVectors[Pick]
			until Dir ~= CurrentDir

			-- Update intent
			Context.World:SetAttribute("GravityMode", Pick)
			Context.World:SetAttribute("GravityDirection", Dir)

			-- Apply physics
			GravityController.SetGravity(Dir, 5)
			UpdateRoomShellCollision(Context.World, Dir)
			game.SoundService.Gravity_SFX:Play()
		end)

		table.insert(RuntimeState.Connections, Connection)
	end

	return RuntimeState
end

local function ApplyPulseWaveRule(Context: RuleContext): RuleRuntimeState
	local RoomCenter, RoomSize = GetRoomBounds(Context.World)

	Context.World:SetAttribute("PulseWave", true)

	--TileController.ForceAllTilesNormal()

	for _, Tile in ipairs(Context.Tiles) do
		if not Tile:IsA("BasePart") then
			continue
		end

		if Tile:GetAttribute("IsBoundary") then
			continue
		end

		Tile:SetAttribute("AlwaysDangerous", false)
		Tile:SetAttribute("IsMissing", false)

		Tile:SetAttribute("CycleEnabled", false)
		Tile:SetAttribute("PressureEnabled", false)

		Tile:SetAttribute("Heat", 0)
		Tile:SetAttribute("HeatCooldownUntil", math.huge)
		Tile:SetAttribute("PressureForcedUntil", nil)

		Tile:SetAttribute("RuleForced", true)
		Tile:SetAttribute("IgnoreActiveSurface", true)

		Tile:SetAttribute("TileType", "Spike")
		Tile:SetAttribute("TileCategory", "Hazard")

		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("StateStartTime", os.clock())

		Tile.Transparency = 0
		Tile.CanCollide = true
		Tile.CanQuery = true
	end

	local GridSize = 11
	local GridCenter = math.ceil(GridSize / 2)

	local WaveSpeed = 4.5

	local ChargingLead = 1          -- warning band is 2 tiles ahead of the danger
	local DangerousHold = 1         -- how many distance steps a tile stays Dangerous
	local ResetDelay = ChargingLead + DangerousHold

	local WaveTypes = {
		--"RadialOut",
		"RadialIn",
		"LeftRight",
		"RightLeft",
		"FrontBack",
		"BackFront",
		"Diag1",
		"Diag2",
	}

	local CurrentWave = "RadialOut"

	-- DistanceLayersBySurface[Surface][Distance] = {Tile, Tile, ...}
	local DistanceLayersBySurface = {}
	local MaxDistanceBySurface = {}

	local CurrentDistanceBySurface = {}
	local PreviousChargeDistanceBySurface = {}

	local function GetDistance(GridX, GridY)
		local DX = GridX - GridCenter
		local DY = GridY - GridCenter

		if CurrentWave == "RadialOut" then
			return math.max(math.abs(DX), math.abs(DY))
		elseif CurrentWave == "RadialIn" then
			return (GridCenter - 1) - math.max(math.abs(DX), math.abs(DY))
		elseif CurrentWave == "LeftRight" then
			return GridX - 1
		elseif CurrentWave == "RightLeft" then
			return (GridSize - 1) - (GridX - 1)
		elseif CurrentWave == "FrontBack" then
			return GridY - 1
		elseif CurrentWave == "BackFront" then
			return (GridSize - 1) - (GridY - 1)
		elseif CurrentWave == "Diag1" then
			return (GridX - 1) + (GridY - 1)
		elseif CurrentWave == "Diag2" then
			return (GridX - 1) + ((GridSize - 1) - (GridY - 1))
		end

		return 0
	end

	local function EnsureSurfaceTables(Surface: string)
		if not DistanceLayersBySurface[Surface] then
			DistanceLayersBySurface[Surface] = {}
			MaxDistanceBySurface[Surface] = 0
			CurrentDistanceBySurface[Surface] = -1
			PreviousChargeDistanceBySurface[Surface] = nil
		end
	end

	local function BuildDistanceLayers()
		table.clear(DistanceLayersBySurface)
		table.clear(MaxDistanceBySurface)
		table.clear(CurrentDistanceBySurface)
		table.clear(PreviousChargeDistanceBySurface)

		for _, Tile in ipairs(Context.Tiles) do
			if not Tile:IsA("BasePart") then
				continue
			end
			if Tile:GetAttribute("IsBoundary") then
				continue
			end

			local GridX = Tile:GetAttribute("GridX")
			local GridY = Tile:GetAttribute("GridY")
			local Surface = Tile:GetAttribute("Surface")

			if not GridX or not GridY or not Surface then
				continue
			end

			EnsureSurfaceTables(Surface)

			local Distance = GetDistance(GridX, GridY)
			local SurfaceLayers = DistanceLayersBySurface[Surface]

			SurfaceLayers[Distance] = SurfaceLayers[Distance] or {}
			table.insert(SurfaceLayers[Distance], Tile)

			if Distance > (MaxDistanceBySurface[Surface] or 0) then
				MaxDistanceBySurface[Surface] = Distance
			end
		end
	end

	local function SetLayerState(Surface: string, Distance: number, State: string, Now: number)
		local SurfaceLayers = DistanceLayersBySurface[Surface]
		if not SurfaceLayers then
			return
		end

		local Layer = SurfaceLayers[Distance]
		if not Layer then
			return
		end

		for _, Tile in ipairs(Layer) do
			if Tile and Tile.Parent then
				local OldState = Tile:GetAttribute("TileState")
				if OldState ~= State then
					Tile:SetAttribute("TileState", State)
					Tile:SetAttribute("StateStartTime", Now)
				end
			end
		end
	end

	local function ResetAllTilesToNormal(Now: number)
		for _, Tile in ipairs(Context.Tiles) do
			if not Tile:IsA("BasePart") then
				continue
			end
			if Tile:GetAttribute("IsBoundary") then
				continue
			end

			if Tile:GetAttribute("TileState") ~= "Normal" then
				Tile:SetAttribute("TileState", "Normal")
				Tile:SetAttribute("StateStartTime", Now)
			end
		end
	end

	local PulseStartTime = os.clock()

	local function StartNewPulse()
		local Now = os.clock()
		ResetAllTilesToNormal(Now)
		
		PulseStartTime = Now
		CurrentWave = WaveTypes[math.random(1, #WaveTypes)]

		BuildDistanceLayers()
		ResetAllTilesToNormal(Now)

		for Surface in pairs(DistanceLayersBySurface) do
			CurrentDistanceBySurface[Surface] = -1
			PreviousChargeDistanceBySurface[Surface] = nil
		end
	end

	StartNewPulse()

	local RuntimeState: RuleRuntimeState = {
		Name = "PulseWave",
		Connections = {},
		Instances = {},
		Data = {},
		Cleanup = function(CleanupContext: RuleContext)
			CleanupContext.World:SetAttribute("PulseWave", false)

			for _, Tile in ipairs(CleanupContext.Tiles) do
				TileController.ResetTile(Tile)
			end
		end,
	}

	local Connection
	Connection = RunService.Heartbeat:Connect(function()
		local Now = os.clock()
		local Elapsed = Now - PulseStartTime

		-- Global step index
		local StepDistance = math.floor(Elapsed * WaveSpeed)

		-- Advance each surface independently
		for Surface in pairs(DistanceLayersBySurface) do
			local CurrentDistance = CurrentDistanceBySurface[Surface] or -1
			if StepDistance == CurrentDistance then
				continue
			end

			CurrentDistanceBySurface[Surface] = StepDistance

			local ChargeDistance = StepDistance + ChargingLead
			local DangerDistance = StepDistance
			local ResetDistance = StepDistance - ResetDelay

			local PreviousChargeDistance = PreviousChargeDistanceBySurface[Surface]
			if PreviousChargeDistance ~= nil and PreviousChargeDistance ~= ChargeDistance then
				if PreviousChargeDistance > DangerDistance then
					SetLayerState(Surface, PreviousChargeDistance, "Normal", Now)
				end
			end
			PreviousChargeDistanceBySurface[Surface] = ChargeDistance

			SetLayerState(Surface, ChargeDistance, "Charging", Now)
			SetLayerState(Surface, DangerDistance, "Dangerous", Now)
			SetLayerState(Surface, ResetDistance, "Normal", Now)

			local MaxDistance = MaxDistanceBySurface[Surface] or 0
			if StepDistance > MaxDistance + ResetDelay + 2 then
				StartNewPulse()
				break
			end
		end
	end)

	table.insert(RuntimeState.Connections, Connection)

	return RuntimeState
end

local function ApplyCircleArenaRule(Context: RuleContext): RuleRuntimeState
	local RoomCenter, RoomSize = GetRoomBounds(Context.World)

	Context.World:SetAttribute("CircleArena", true)

	-- Reset tile system state
	TileController.ForceAllTilesNormal()

	-- Start from a clean slate
	for _, Tile in ipairs(Context.Tiles) do
		if not Tile:IsA("BasePart") then
			continue
		end

		Tile:SetAttribute("AlwaysDangerous", false)
		Tile:SetAttribute("IsMissing", false)

		Tile.Transparency = 0
		Tile.CanCollide = true
		Tile.CanQuery = true

		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("StateStartTime", os.clock())

		Tile:SetAttribute("Heat", 0)
		Tile:SetAttribute("HeatCooldownUntil", 0)
		Tile:SetAttribute("PressureForcedUntil", nil)

		Tile:SetAttribute("RuleForced", nil)

		Tile:SetAttribute("CycleEnabled", false)
		Tile:SetAttribute("PressureEnabled", false)
	end

	local GridCenter = math.ceil(11 / 2)
	local InnerRadius = 3.0
	local OuterRadius = 5.25

	for _, Tile in ipairs(Context.Tiles) do
		if not Tile:IsA("BasePart") then
			continue
		end

		local GridX = Tile:GetAttribute("GridX")
		local GridY = Tile:GetAttribute("GridY")
		if not GridX or not GridY then
			continue
		end

		local dx = GridX - GridCenter
		local dy = GridY - GridCenter
		local dist = math.sqrt(dx * dx + dy * dy)

		if dist < InnerRadius or dist > OuterRadius then
			Tile:SetAttribute("RuleForced", true)
			Tile:SetAttribute("IsMissing", true)

			Tile:SetAttribute("CycleEnabled", false)
			Tile:SetAttribute("PressureEnabled", false)

			Tile:SetAttribute("TileState", "Normal")
			Tile:SetAttribute("StateStartTime", os.clock())

			Tile.Transparency = 1
			Tile.CanCollide = false
			Tile.CanQuery = false
		end
	end

	-- Re-enable gameplay on the remaining ring tiles
	for _, Tile in ipairs(Context.Tiles) do
		if not Tile:IsA("BasePart") then
			continue
		end
		if Tile:GetAttribute("IsBoundary") then
			continue
		end
		if Tile:GetAttribute("IsMissing") then
			continue
		end

		Tile:SetAttribute("RuleForced", nil)

		Tile:SetAttribute("CycleEnabled", true)
		Tile:SetAttribute("PressureEnabled", true)

		Tile:SetAttribute("Heat", 0)
		Tile:SetAttribute("HeatCooldownUntil", 0)
		Tile:SetAttribute("PressureForcedUntil", nil)

		Tile:SetAttribute("TileState", "Normal")
		Tile:SetAttribute("StateStartTime", os.clock())
	end

	-- Always-dangerous on ring hazards
	local Candidates = {}
	for _, Tile in ipairs(Context.Tiles) do
		if not Tile:IsA("BasePart") then
			continue
		end
		if Tile:GetAttribute("IsBoundary") then
			continue
		end
		if Tile:GetAttribute("IsMissing") then
			continue
		end
		if Tile:GetAttribute("TileCategory") ~= "Hazard" then
			continue
		end

		table.insert(Candidates, Tile)
	end

	local AlwaysCount = math.clamp(math.random(3, 6), 0, #Candidates)
	for i = 1, AlwaysCount do
		local idx = math.random(1, #Candidates)
		local Tile = table.remove(Candidates, idx)

		Tile:SetAttribute("AlwaysDangerous", true)
		Tile:SetAttribute("CycleEnabled", false)
		Tile:SetAttribute("PressureEnabled", false)
		Tile:SetAttribute("RuleForced", true)

		Tile:SetAttribute("TileState", "Dangerous")
		Tile:SetAttribute("StateStartTime", os.clock())
	end

	TileController.RecomputeDangerousCap(Context.RoomIndex, 0.5)

	local RuntimeState: RuleRuntimeState = {
		Name = "CircleArena",
		Connections = {},
		Instances = {},
		Data = {},
		Cleanup = function(CleanupContext: RuleContext)
			CleanupContext.World:SetAttribute("CircleArena", false)

			--TileController.ApplyMaxDangerousMultiplier(1)

			for _, Tile in ipairs(CleanupContext.Tiles) do
				if Tile then
					TileController.ResetTile(Tile)
				end
			end
		end,
	}

	return RuntimeState
end

local RuleDefinitions: { [string]: RuleDefinition } = {
	Gravity = {
		Name = "Gravity",
		MinRoom = 1,
		Apply = ApplyGravityRule,
	},

	PulseWave = {
		Name = "PulseWave",
		MinRoom = 3,
		Apply = ApplyPulseWaveRule,
	},

	CircleArena = {
		Name = "CircleArena",
		MinRoom = 3,
		Apply = ApplyCircleArenaRule,
	},
}

local function GetAvailableRules(RoomIndex: number): { RuleDefinition }
	local AvailableRules: { RuleDefinition } = {}

	for Name, Rule in pairs(RuleDefinitions) do
		if Name == "Gravity" then
			continue
		end

		if RoomIndex >= Rule.MinRoom then
			table.insert(AvailableRules, Rule)
		end
	end

	return AvailableRules
end

local function ShouldAddStackRule(RoomIndex: number): boolean
	if RoomIndex < 3 then
		return false
	elseif RoomIndex <= 4 then
		return math.random() < 0.25
	elseif RoomIndex <= 6 then
		return math.random() < 0.4
	elseif RoomIndex <= 8 then
		return math.random() < 0.55
	else
		return math.random() < 0.7
	end
end

local function ChooseRules(RoomIndex: number): { RuleDefinition }
	local ChosenRules: { RuleDefinition } = {}
	local AvailableRules = GetAvailableRules(RoomIndex)

	if #AvailableRules == 0 then
		return ChosenRules
	end

	if ShouldAddStackRule(RoomIndex) then
		local PickIndex = math.random(1, #AvailableRules)
		table.insert(ChosenRules, AvailableRules[PickIndex])
	end

	return ChosenRules
end

function RuleController.ClearRules(Context: RuleContext)
	for _, RuleState in ipairs(ActiveRuleStates) do
		local CleanupContext = RuleState.Context or Context

		for _, Connection in ipairs(RuleState.Connections) do
			Connection:Disconnect()
		end

		for _, InstanceItem in ipairs(RuleState.Instances) do
			if InstanceItem and InstanceItem.Parent then
				InstanceItem:Destroy()
			end
		end

		if RuleState.Cleanup then
			RuleState.Cleanup(CleanupContext)
		end
	end

	table.clear(ActiveRuleStates)
end

function RuleController.ApplyNewRules(RoomIndex: number, Context: RuleContext): { string }
	Context.RoomIndex = RoomIndex

	RuleController.ClearRules(Context)

	local ActiveRuleNames: { string } = {}

	local GravityRule = RuleDefinitions.Gravity
	if GravityRule and RoomIndex >= GravityRule.MinRoom then
		local GravityState = GravityRule.Apply(Context)
		GravityState.Context = Context

		table.insert(ActiveRuleStates, GravityState)
		table.insert(ActiveRuleNames, GravityRule.Name)
		warn("Rule", #ActiveRuleNames, GravityRule.Name)
	end

	local SelectedRules = ChooseRules(RoomIndex)

	for _, Rule in ipairs(SelectedRules) do
		local RuleState = Rule.Apply(Context)
		RuleState.Context = Context

		table.insert(ActiveRuleStates, RuleState)
		table.insert(ActiveRuleNames, Rule.Name)
		warn("Rule", #ActiveRuleNames, Rule.Name)
	end

	Context.World:SetAttribute("ActiveRules", table.concat(ActiveRuleNames, ", "))

	return ActiveRuleNames
end

function RuleController.GetActiveRules(): { string }
	local Names: { string } = {}
	for _, RuleState in ipairs(ActiveRuleStates) do
		table.insert(Names, RuleState.Name)
	end
	return Names
end

function RuleController.GetDefinitions()
	return RuleDefinitions
end

return RuleController
