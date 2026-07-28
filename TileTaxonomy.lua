-- Decides which tile types are allowed for a given room
local TileTaxonomy = {}

-- Valid surfaces used by TileGenerator
local Surfaces = {
	Floor = true,
	Ceiling = true,
	WallLeft = true,
	WallBack = true,
}

local AllTileTypes = {
	Neutral = {
		Name = "Neutral",
		Category = "Neutral",
		MinRoom = 1,
		AllowedSurfaces = Surfaces,
		Weight = 1.0,
	},

	LuckyTile = {
		Name = "LuckyTile",
		Category = "Constraint",
		MinRoom = 1,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
			Ceiling = true,
		},
		Weight = 0.35,
	},

	Spike = {
		Name = "Spike",
		Category = "Hazard",
		MinRoom = 1,
		AllowedSurfaces = Surfaces,
		Weight = 1.2,
	},

	Pulse = {
		Name = "Pulse",
		Category = "Hazard",
		MinRoom = 4,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
			Ceiling = false,
		},
		Weight = 0.75,
	},

	Laser = {
		Name = "Laser",
		Category = "Hazard",
		MinRoom = 1,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
			Ceiling = true,
		},
		Weight = 0.6,
	},

	PopUp = {
		Name = "PopUp",
		Category = "Movement",
		MinRoom = 1,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
			Ceiling = false,
		},
		Weight = 0.3,
	},

	Conveyor = {
		Name = "Conveyor",
		Category = "Movement",
		MinRoom = 1,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
		},
		Weight = 0.35,
	},

	Bounce = {
		Name = "Spring",
		Category = "Movement",
		MinRoom = 1,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
			Ceiling = true,
		},
		Weight = 0.28,
	},

	Slide = {
		Name = "Slide",
		Category = "Movement",
		MinRoom = 7,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
		},
		Weight = 0.22,
	},

	Tilt = {
		Name = "Tilt",
		Category = "Movement",
		MinRoom = 9,
		AllowedSurfaces = {
			Floor = true,
			WallLeft = true,
			WallBack = true,
		},
		Weight = 0.18,
	},

	Fragile = {
		Name = "Fragile",
		Category = "Constraint",
		MinRoom = 1,
		AllowedSurfaces = Surfaces,
		Weight = 0.35,
	},

	Void = {
		Name = "Void",
		Category = "Constraint",
		MinRoom = 12,
		AllowedSurfaces = {
			Floor = true,
		},
		Weight = 0.22,
	},

	Freeze = {
		Name = "Freeze",
		Category = "Constraint",
		MinRoom = 1,
		AllowedSurfaces = Surfaces,
		Weight = 0.30,
	},

	Shrink = {
		Name = "Shrink",
		Category = "Constraint",
		MinRoom = 10,
		AllowedSurfaces = Surfaces,
		Weight = 0.25,
	},
}

local DifficultyProfiles = {
	Easy = {
		MaxHazardRatio = 0.50,
		MaxMovementRatio = 0.18,
		MaxConstraintRatio = 0.12,

		MaxLuckyTiles = 1,
		LuckyWeightMultiplier = 0.8,
	},

	Medium = {
		MaxHazardRatio = 0.55,
		MaxMovementRatio = 0.22,
		MaxConstraintRatio = 0.15,

		MaxLuckyTiles = 1,
		LuckyWeightMultiplier = 1.0,
	},

	Hard = {
		MaxHazardRatio = 0.60,
		MaxMovementRatio = 0.25,
		MaxConstraintRatio = 0.18,

		MaxLuckyTiles = 2,
		LuckyWeightMultiplier = 1.2,
	},
}

local AdjacentClusterPenalty = 0.28
local NearbyClusterPenalty = 0.55
local SameCategoryPenalty = 0.65
local SurfaceTypeSpreadPenalty = 1.45
local SurfaceCategorySpreadPenalty = 1.15
local PathNeutralBoost = 1.9
local RepeatPenalty = 0.45
local RepeatSpikePenalty = 0.55

local function GetDifficultyTier(RoomIndex: number): string
	if RoomIndex <= 3 then
		return "Easy"
	elseif RoomIndex <= 8 then
		return "Medium"
	else
		return "Hard"
	end
end

local function GetGridKey(GridX: number, GridY: number): string
	return tostring(GridX) .. "_" .. tostring(GridY)
end

local function GetSurfaceState(Profile, Surface: string)
	if not Surface then
		warn("TileTaxonomy: Surface is nil, skipping")
		return nil
	end
	
	if not Profile.RoomState then
		Profile.RoomState = {
			LuckyCount = 0,
			SurfaceStates = {}
		}
	end

	local RoomState = Profile.RoomState
	RoomState.SurfaceStates = RoomState.SurfaceStates or {}

	local SurfaceState = RoomState.SurfaceStates[Surface]
	if SurfaceState then
		return SurfaceState
	end

	SurfaceState = {
		PlacedCount = 0,
		TypeCounts = {},
		CategoryCounts = {},
		Grid = {},
	}

	RoomState.SurfaceStates[Surface] = SurfaceState
	return SurfaceState
end

local function GetPlacedInfo(Profile, Surface: string, GridX: number, GridY: number)
	local SurfaceState = GetSurfaceState(Profile, Surface)
	if not SurfaceState then
		return nil
	end

	return SurfaceState.Grid[GetGridKey(GridX, GridY)]
end

local function CountNeighbors(Profile, Surface: string, GridX: number, GridY: number, TypeName: string, CategoryName: string)
	local AdjacentSameType = 0
	local NearbySameType = 0
	local AdjacentSameCategory = 0
	local NearbyFilled = 0
	local AdjacentFilled = 0

	for OffsetX = -1, 1 do
		for OffsetY = -1, 1 do
			if OffsetX == 0 and OffsetY == 0 then
				continue
			end

			local Other = GetPlacedInfo(Profile, Surface, GridX + OffsetX, GridY + OffsetY)
			if Other then
				local IsAdjacent = math.abs(OffsetX) + math.abs(OffsetY) == 1

				NearbyFilled += 1
				if IsAdjacent then
					AdjacentFilled += 1
				end

				if Other.TypeName == TypeName then
					NearbySameType += 1
					if IsAdjacent then
						AdjacentSameType += 1
					end
				end

				if Other.Category == CategoryName then
					if IsAdjacent then
						AdjacentSameCategory += 1
					end
				end
			end
		end
	end

	return AdjacentSameType, NearbySameType, AdjacentSameCategory, AdjacentFilled, NearbyFilled
end

local function GetSurfaceTypeRatio(Profile, Surface: string, TypeName: string): number
	local SurfaceState = GetSurfaceState(Profile, Surface)
	if not SurfaceState or SurfaceState.PlacedCount <= 0 then
		return 0
	end

	local Count = SurfaceState.TypeCounts[TypeName] or 0
	return Count / SurfaceState.PlacedCount
end

local function GetSurfaceCategoryRatio(Profile, Surface: string, Category: string): number
	local SurfaceState = GetSurfaceState(Profile, Surface)
	if not SurfaceState or SurfaceState.PlacedCount <= 0 then
		return 0
	end

	local Count = SurfaceState.CategoryCounts[Category] or 0
	return Count / SurfaceState.PlacedCount
end

local function RegisterPlacedTile(Profile, Tile, TypeName: string, Category: string)
	local Surface = Tile:GetAttribute("Surface")
	local GridX = Tile:GetAttribute("GridX")
	local GridY = Tile:GetAttribute("GridY")

	if not Surface or not GridX or not GridY then
		return
	end

	local SurfaceState = GetSurfaceState(Profile, Surface)
	if not SurfaceState then
		return
	end

	local Key = GetGridKey(GridX, GridY)
	local Existing = SurfaceState.Grid[Key]

	if Existing then
		local OldType = Existing.TypeName
		local OldCategory = Existing.Category

		if OldType then
			SurfaceState.TypeCounts[OldType] = math.max(0, (SurfaceState.TypeCounts[OldType] or 1) - 1)
		end

		if OldCategory then
			SurfaceState.CategoryCounts[OldCategory] = math.max(0, (SurfaceState.CategoryCounts[OldCategory] or 1) - 1)
		end
	else
		SurfaceState.PlacedCount += 1
	end

	SurfaceState.Grid[Key] = {
		TypeName = TypeName,
		Category = Category,
	}

	SurfaceState.TypeCounts[TypeName] = (SurfaceState.TypeCounts[TypeName] or 0) + 1
	SurfaceState.CategoryCounts[Category] = (SurfaceState.CategoryCounts[Category] or 0) + 1
end

local function PickCategory(Profile)
	local Limits = Profile.CategoryLimits

	local Categories = {
		{ Name = "Hazard", Weight = Limits.Hazard },
		{ Name = "Movement", Weight = Limits.Movement },
		{ Name = "Constraint", Weight = Limits.Constraint },
		{ Name = "Neutral", Weight = Profile.NeutralBias },
	}

	local Total = 0
	for _, C in ipairs(Categories) do
		Total += C.Weight
	end

	local Roll = math.random() * Total

	for _, C in ipairs(Categories) do
		Roll -= C.Weight
		if Roll <= 0 then
			return C.Name
		end
	end

	return "Hazard"
end

local function BuildCandidates(Tile, Profile, RequestedCategory: string?)
	local Surface = Tile:GetAttribute("Surface")
	local GridX = Tile:GetAttribute("GridX")
	local GridY = Tile:GetAttribute("GridY")
	local LastType = Tile:GetAttribute("LastDangerousType")

	local RoomState = Profile.RoomState
	local LuckyCount = RoomState and RoomState.LuckyCount or 0
	local MaxLuckyTiles = Profile.MaxLuckyTiles or math.huge

	local Category = RequestedCategory or PickCategory(Profile)
	local Candidates = {}

	for _, Def in ipairs(Profile.AllowedTiles) do
		if Def.Category == Category
			and Def.AllowedSurfaces[Surface]
			and Def.Category ~= "Neutral"
		then
			if Def.Name == "LuckyTile"
				and LuckyCount >= MaxLuckyTiles
			then
				continue
			end

			local Weight = Def.Weight or 1

			if Def.Name == "LuckyTile" then
				Weight *= (Profile.LuckyWeightMultiplier or 1)
			end

			if Def.Category == "Neutral" then
				Weight *= (Profile.NeutralBias or 1)
			end

			if GridX and GridY and Surface then
				local AdjacentSameType, NearbySameType, AdjacentSameCategory, AdjacentFilled =
					CountNeighbors(Profile, Surface, GridX, GridY, Def.Name, Def.Category)

				if AdjacentSameType > 0 then
					Weight *= (AdjacentClusterPenalty ^ AdjacentSameType)
				end

				local DiagonalSameType = math.max(0, NearbySameType - AdjacentSameType)
				if DiagonalSameType > 0 then
					Weight *= (NearbyClusterPenalty ^ DiagonalSameType)
				end

				if AdjacentSameCategory > 0 and Def.Category ~= "Neutral" then
					Weight *= (SameCategoryPenalty ^ AdjacentSameCategory)
				end

				if Def.Category == "Neutral" and AdjacentFilled >= 2 then
					Weight *= PathNeutralBoost
				end
			end

			local SurfaceTypeRatio = GetSurfaceTypeRatio(Profile, Surface, Def.Name)
			if SurfaceTypeRatio > 0 then
				Weight /= (1 + SurfaceTypeRatio * SurfaceTypeSpreadPenalty)
			end

			local SurfaceCategoryRatio = GetSurfaceCategoryRatio(Profile, Surface, Def.Category)
			if SurfaceCategoryRatio > 0 and Def.Category ~= "Neutral" then
				Weight /= (1 + SurfaceCategoryRatio * SurfaceCategorySpreadPenalty)
			end

			if Def.Name == LastType then
				Weight *= RepeatPenalty
			end

			if Def.Category == "Movement"
				and Tile:GetAttribute("LastMovementTile")
			then
				Weight *= RepeatPenalty
			end

			if Def.Name == "Spike"
				and Tile:GetAttribute("LastDangerousType") == "Spike"
			then
				Weight *= RepeatSpikePenalty
			end

			if Weight > 0 then
				table.insert(Candidates, {
					Def = Def,
					Weight = Weight,
				})
			end
		end
	end

	return Candidates
end

local function RollCandidate(Candidates)
	local Total = 0
	for _, Candidate in ipairs(Candidates) do
		Total += Candidate.Weight
	end

	if Total <= 0 then
		return nil
	end

	local Roll = math.random() * Total

	for _, Candidate in ipairs(Candidates) do
		Roll -= Candidate.Weight
		if Roll <= 0 then
			return Candidate.Def
		end
	end

	return Candidates[#Candidates] and Candidates[#Candidates].Def or nil
end


function TileTaxonomy.PickInitialTileType(Tile, Profile)
	local Candidates = BuildCandidates(Tile, Profile, nil)
	local Picked = RollCandidate(Candidates)

	if not Picked then
		Picked = AllTileTypes.Neutral
	end

	RegisterPlacedTile(Profile, Tile, Picked.Name, Picked.Category)

	if Picked.Name == "LuckyTile" and Profile.RoomState then
		Profile.RoomState.LuckyCount = (Profile.RoomState.LuckyCount or 0) + 1
	end

	Tile:SetAttribute("TileType", Picked.Name)
	Tile:SetAttribute("TileCategory", Picked.Category)

	return Picked.Name
end

local function SeedSurface(Profile, Tile)
	local Surface = Tile:GetAttribute("Surface")
	if not Surface then return end
	local SurfaceState = GetSurfaceState(Profile, Surface)

	if not SurfaceState or SurfaceState.PlacedCount > 0 then
		return
	end

	local World = Tile.Parent and Tile.Parent.Parent
	if not World then
		return
	end

	for _, OtherTile in ipairs(World:GetChildren()) do
		if OtherTile:GetAttribute("Surface") == Surface then

			local TypeName = OtherTile:GetAttribute("TileType") or "Neutral"
			local Category = OtherTile:GetAttribute("TileCategory") or "Neutral"

			RegisterPlacedTile(Profile, OtherTile, TypeName, Category)
		end
	end
end

function TileTaxonomy.InheritSurfaceHistory(Profile, FromSurface, ToSurface)
	if not Profile or not Profile.RoomState then
		return
	end

	local States = Profile.RoomState.SurfaceStates
	if not States then
		return
	end

	local From = States[FromSurface]
	if not From then
		return
	end

	States[ToSurface] = {
		PlacedCount = From.PlacedCount,
		TypeCounts = table.clone(From.TypeCounts),
		CategoryCounts = table.clone(From.CategoryCounts),
		Grid = table.clone(From.Grid),
	}
end

function TileTaxonomy.PickDangerousType(Tile, Profile, PickOnlyHazards)
	local Surface = Tile:GetAttribute("Surface")
	if not Surface then return "Spike" end
	SeedSurface(Profile, Tile)
	
	local ExistingType = Tile:GetAttribute("TileType")
	local ExistingCategory = Tile:GetAttribute("TileCategory")

	local RequestedCategory = PickOnlyHazards and "Hazard" or nil
	
	-- LuckyTile special roll
	if not RequestedCategory and Profile.RoomState then
		local LuckyCount = Profile.RoomState.LuckyCount or 0
		local MaxLuckyTiles = Profile.MaxLuckyTiles or 0

		if LuckyCount < MaxLuckyTiles then
			local LuckyChance = 0.015 -- 1.5% per tile

			if math.random() < LuckyChance then
				for _, Def in ipairs(Profile.AllowedTiles) do
					if Def.Name == "LuckyTile" and Def.AllowedSurfaces[Surface] then
						Tile:SetAttribute("LastDangerousType", "LuckyTile")
						Tile:SetAttribute("DangerousType", "LuckyTile")

						RegisterPlacedTile(Profile, Tile, "LuckyTile", "Constraint")

						Profile.RoomState.LuckyCount += 1

						return "LuckyTile"
					end
				end
			end
		end
	end
	
	local Candidates = BuildCandidates(Tile, Profile, RequestedCategory)
	local Picked = RollCandidate(Candidates)

	if not Picked then
		Picked = AllTileTypes.Spike
	end

	Tile:SetAttribute("LastDangerousType", Picked.Name)
	Tile:SetAttribute("DangerousType", Picked.Name)

	if Picked.Category == "Movement" then
		Tile:SetAttribute("LastMovementTile", true)
	else
		Tile:SetAttribute("LastMovementTile", false)
	end

	if Profile.RoomState and Picked.Name == "LuckyTile" then
		Profile.RoomState.LuckyCount = (Profile.RoomState.LuckyCount or 0) + 1
	end

	RegisterPlacedTile(Profile, Tile, Picked.Name, Picked.Category)

	return Picked.Name
end

function TileTaxonomy.GetRoomTileProfile(RoomIndex: number, IsRealGeneration: boolean?)
	local DifficultyTier = GetDifficultyTier(RoomIndex)
	local DifficultyProfile = DifficultyProfiles[DifficultyTier]

	local AllowedTiles = {}

	local CategoryLimits = {
		Hazard = DifficultyProfile.MaxHazardRatio,
		Movement = DifficultyProfile.MaxMovementRatio,
		Constraint = DifficultyProfile.MaxConstraintRatio,
	}

	table.insert(AllowedTiles, AllTileTypes.Neutral)

	for _, TileDefinition in pairs(AllTileTypes) do
		if TileDefinition.Name ~= "Neutral"
			and RoomIndex >= TileDefinition.MinRoom
		then
			table.insert(AllowedTiles, TileDefinition)
		end
	end

	local Profile = {
		RoomIndex = RoomIndex,
		DifficultyTier = DifficultyTier,

		AllowedTiles = AllowedTiles,
		CategoryLimits = CategoryLimits,

		NeutralBias =
			1
		- CategoryLimits.Hazard
		- CategoryLimits.Movement
		- CategoryLimits.Constraint,

		MaxLuckyTiles = DifficultyProfile.MaxLuckyTiles,
		LuckyWeightMultiplier = DifficultyProfile.LuckyWeightMultiplier,

		RoomState = IsRealGeneration and {
			LuckyCount = 0,
			SurfaceStates = {},
		} or nil,
	}

	if Profile.RoomState then
		local MaxLuckyTiles = Profile.MaxLuckyTiles or 0

		if MaxLuckyTiles <= 0 then
			for Index = #Profile.AllowedTiles, 1, -1 do
				if Profile.AllowedTiles[Index].Name == "LuckyTile" then
					table.remove(Profile.AllowedTiles, Index)
				end
			end
		end
	end

	return Profile
end

TileTaxonomy.RegisterPlacedTile = RegisterPlacedTile

return TileTaxonomy
