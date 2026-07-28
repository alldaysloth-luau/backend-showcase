-- Responsible for physically generating tiles in the world
local TileGenerator = {}

local TileTaxonomy = require(script.Parent.TileTaxonomy)

local RoomConfig = {
	RoomSize = 11,
	TileSize = Vector3.new(8,8,8),
	TileHeightOffset = 0,
	TileMaterial = Enum.Material.Slate,
	TileColor = Color3.fromRGB(149, 116, 79),
}

local Surfaces = {
	Floor = {
		Normal = Vector3.new(0, -1, 0),
		Right  = Vector3.new(1, 0, 0),
		Up     = Vector3.new(0, 0, 1),
	},
	Ceiling = {
		Normal = Vector3.new(0, 1, 0),
		Right  = Vector3.new(1, 0, 0),
		Up     = Vector3.new(0, 0, -1),
	},
	WallLeft = {
		Normal = Vector3.new(-1, 0, 0),
		Right  = Vector3.new(0, 0, 1),
		Up     = Vector3.new(0, 1, 0),
	},
	WallBack = {
		Normal = Vector3.new(0, 0, 1),
		Right  = Vector3.new(1, 0, 0),
		Up     = Vector3.new(0, 1, 0),
	},
}

local function ApplyColorVariation(BaseColor: Color3)
	local h, s, v = BaseColor:ToHSV()
	h = (h + (math.random() * 0.04 - 0.02)) % 1
	v = math.clamp(v + (math.random() * 0.1 - 0.05), 0, 1)
	return Color3.fromHSV(h, s, v)
end

local function CreateTilePart(TileMaterial, TileColor)
	local Part = script:WaitForChild("Tile"):Clone()
	Part.Anchored = true
	Part.Size = RoomConfig.TileSize
	Part.Material = TileMaterial or RoomConfig.TileMaterial
	Part.Color = TileColor and ApplyColorVariation(TileColor) or ApplyColorVariation(RoomConfig.TileColor)
	Part.TopSurface = Enum.SurfaceType.Smooth
	Part.BottomSurface = Enum.SurfaceType.Smooth
	Part.Name = "Tile"
	return Part
end

local function GetSurfaceCFrame(GridX, GridY, RoomOrigin, SurfaceName)
	local S = Surfaces[SurfaceName]
	local Step = RoomConfig.TileSize.X
	local Half = (RoomConfig.RoomSize * Step) / 2

	local OffsetX = (GridX - 0.5) * Step - Half
	local OffsetY = (GridY - 0.5) * Step - Half
	local NormalOffset = Half - Step * 0.5 + RoomConfig.TileHeightOffset

	local WorldPos =
		RoomOrigin
		+ S.Right * OffsetX
		+ S.Up * OffsetY
		+ S.Normal * NormalOffset

	return CFrame.fromMatrix(WorldPos, S.Right, S.Up)
end

local function Quantize(v: Vector3, step: number)
	return Vector3.new(
		math.round(v.X / step) * step,
		math.round(v.Y / step) * step,
		math.round(v.Z / step) * step
	)
end

local function VecKey(v: Vector3)
	return string.format("%d_%d_%d", v.X, v.Y, v.Z)
end

function TileGenerator.GenerateRoom(RoomIndex: number, Parent: Instance, RoomOrigin: Vector3, TileMaterial, TileColor)
	RoomOrigin = RoomOrigin or Vector3.zero

	local RoomFolder = Instance.new("Folder")
	RoomFolder.Name = "Room_" .. RoomIndex
	RoomFolder.Parent = Parent
	
	local Step = RoomConfig.TileSize.X
	local RoomWidth = RoomConfig.RoomSize * Step
	local Half = RoomWidth / 2
	local BorderOffset = Half - Step * 0.5

	local function CreateWall(SurfaceName, Size, Position)
		local Part = Instance.new("Part")
		Part.Name = SurfaceName
		Part.Anchored = true
		Part.Transparency = 1
		Part.CanCollide = true
		Part.CanQuery = false
		Part.CanTouch = false
		Part.Size = Size
		Part.Position = Position

		Part:SetAttribute("Border", SurfaceName)
		Part.Parent = RoomFolder

		return Part
	end

	CreateWall(
		"Floor",
		Vector3.new(RoomWidth, Step, RoomWidth),
		RoomOrigin + Vector3.new(0, -BorderOffset, 0)
	)

	CreateWall(
		"Ceiling",
		Vector3.new(RoomWidth, Step, RoomWidth),
		RoomOrigin + Vector3.new(0, BorderOffset, 0)
	)

	CreateWall(
		"WallBack",
		Vector3.new(RoomWidth, RoomWidth, Step),
		RoomOrigin + Vector3.new(0, 0, BorderOffset)
	)

	CreateWall(
		"WallLeft",
		Vector3.new(Step, RoomWidth, RoomWidth),
		RoomOrigin + Vector3.new(-BorderOffset, 0, 0)
	)

	local TileProfile = TileTaxonomy.GetRoomTileProfile(RoomIndex, true)
	local TilesPerSurface = RoomConfig.RoomSize ^ 2

	local AllTiles = {}
	local SpatialMap = {}
	local OverlapSet = {}

	for SurfaceName in pairs(Surfaces) do
		local SurfaceFolder = Instance.new("Folder")
		SurfaceFolder.Name = SurfaceName
		SurfaceFolder.Parent = RoomFolder

		for gx = 1, RoomConfig.RoomSize do
			for gy = 1, RoomConfig.RoomSize do
				local Tile = CreateTilePart(TileMaterial, TileColor)
				Tile.CFrame = GetSurfaceCFrame(gx, gy, RoomOrigin, SurfaceName)
				Tile.Parent = SurfaceFolder

				Tile:SetAttribute("GridX", gx)
				Tile:SetAttribute("GridY", gy)
				Tile:SetAttribute("RoomIndex", RoomIndex)
				Tile:SetAttribute("Surface", SurfaceName)

				local q = Quantize(Tile.Position, RoomConfig.TileSize.X)
				local key = VecKey(q)

				if SpatialMap[key] then
					OverlapSet[Tile] = true
					OverlapSet[SpatialMap[key]] = true
				else
					SpatialMap[key] = Tile
				end

				table.insert(AllTiles, Tile)
			end
		end
	end
	
	local CategoryCounts = {
		Hazard = 0,
		Movement = 0,
		Constraint = 0,
	}

	for _, Tile in ipairs(AllTiles) do
		local IsBoundary = OverlapSet[Tile] == true
		Tile:SetAttribute("IsBoundary", IsBoundary)

		local PickedName = TileTaxonomy.PickInitialTileType(Tile, TileProfile)

		local TileTypeData
		for _, Def in ipairs(TileProfile.AllowedTiles) do
			if Def.Name == PickedName then
				TileTypeData = Def
				break
			end
		end

		Tile:SetAttribute("TileType", TileTypeData.Name)
		Tile:SetAttribute("TileCategory", TileTypeData.Category)
		Tile:SetAttribute("TileState", "Normal")

		if not IsBoundary then
			local cat = TileTypeData.Category
			if CategoryCounts[cat] ~= nil and CategoryCounts[cat] < (TileProfile.CategoryLimits[cat] or 1) then
				CategoryCounts[cat] += 1 / TilesPerSurface
			end
		end
	end
	
	local HasNeutral = false

	for _, Tile in ipairs(AllTiles) do
		if Tile:GetAttribute("TileType") == "Neutral" then
			HasNeutral = true
			break
		end
	end

	if not HasNeutral then
		local RandomTile = AllTiles[math.random(#AllTiles)]
		RandomTile:SetAttribute("TileType", "Neutral")
		RandomTile:SetAttribute("TileCategory", "Neutral")
	end

	return RoomFolder, TileProfile
end

return TileGenerator
