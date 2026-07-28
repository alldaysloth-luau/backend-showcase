-- Lobby/Hub server:
--   Matchmaking.QueuePlayer(Player, GameMode, Region)
--   Matchmaking.QueueParty(PartyPlayers, GameMode, Region) -- optional
--   Matchmaking.QueueRanked(Player, Region, RankTier)
--
-- Run server:
--   local Info = Matchmaking.GetRunInfo()
--   Matchmaking.HostBeginJoinable(Info.Mode, Info.Region, Info.AccessCode, Info.Capacity, Info.RunId)
--   Matchmaking.HostLockRun(Info.Mode, Info.Region, Info.AccessCode) -- When countdown ends / gameplay begins
--   Players.PlayerAdded:Connect(function(P) Matchmaking.HostValidatePlayer(P, RunStarted, Info) end)
--   Players.PlayerRemoving:Connect(function(P)
--       if Info.Mode == "Ranked" and not RunStarted then
--           Matchmaking.AddRankedWarning(P) -- True dodge before match start
--       end
--   end)

local Matchmaking = {}

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local MatchStatus = Remotes:WaitForChild("MatchStatus")

local MessagingService = game:GetService("MessagingService")
local PARTY_TOPIC = "PartyStatus#001"

local CONFIG = {
	-- Each mode has its own run place
	RunPlaceIds = {
		Normal   = 104261294034000,
		Hardcore = 104261294034000,
		Speedrun = 104261294034000,
		Ranked   = 104261294034000,
	},

	MetricsEnabled = true,
	MinSearchTime = 5,
	SearchRetryInterval = 0.6,

	-- Soft queue timeout
	TeleportFailRequeueThreshold = 2,

	-- Ranked anti-dodge (persistent)
	RankedWarningsEnabled = true,
	RankedPenaltyStoreName = "RankedPenalties#001",
	RankedWarningExpiry = 7 * 24 * 60 * 60, -- 7 days
	RankedMaxWarnings = 3,
	RankedBanDuration = 7 * 24 * 60 * 60, -- 1 week

	-- How long to keep fill-time samples (seconds)
	MetricsWindow = 600,

	-- Bump when data layout changed
	SortedMapName = "RunPool#005",

	-- How many candidates to scan per queue attempt
	ScanLimit = 30,

	-- MemoryStore entry lifetime (host refreshes while joinable)
	EntryTTL = 75,

	-- Host refresh interval
	HeartbeatInterval = 18,

	-- Buffer to reduce overfill from in-flight teleports.
	-- Host advertises PlayerCount = (#players + buffer), clamped to Capacity.
	AdvertiseBufferSlots = 1,

	-- Teleport retry tuning (safe, not spammy)
	TeleportRetryCount = 2, -- 2 extra attempts
	TeleportRetryMinDelay = 0.35,
	TeleportRetryMaxDelay = 0.85,

	-- Region defaults/validation
	DefaultRegion = "EU",
	ValidRegions = {
		ASIA = true,
		AMERICA = true,
		EUROPE = true,
		AFRICA = true,

		-- Short aliases
		AS = true,
		NA = true,
		EU = true,
		AF = true,
	},
	
	MMR = {
		DefaultMMR = 1000,

		-- Base allowed delta at queue start
		BaseDelta = {
			Normal = 400,
			Hardcore = 250,
			Speedrun = 1000, -- Effectively ignored
			Ranked = 100,
		},

		-- How fast window expands per second
		DeltaGrowthPerSecond = {
			Normal = 120,
			Hardcore = 100,
			Speedrun = 1000,
			Ranked = 75,
		},
	},

	-- If true, warns extra logs
	Debug = false,
}

-- Metrics (lightweight, server-local aggregation)
local Metrics = {
	Redirects = {
		OverCapacity = 0,
		RunStarted = 0,
		RunIdMismatch = 0,
	},

	-- Fill time tracking per mode
	-- [Mode] = { Total = number, Count = number }
	FillTimes = {},
}

local ModeCapacities = {
	Normal = 5,
	Hardcore = 5,
	Speedrun = 1,
	Ranked = 2,
}

local RankedTiers = {
	"Bronze",
	"Silver",
	"Gold",
	"Platinum",
	"Diamond",
	"Ascendant",
}

local ActiveQueues = {} 
-- [UserId] = true
-- [PartyId] = true

local RankedTierIndex = {}
for i, Tier in ipairs(RankedTiers) do
	RankedTierIndex[Tier] = i
end

-- Ranked penalties (persistent)
local RankedPenaltyStore = DataStoreService:GetDataStore(CONFIG.RankedPenaltyStoreName)

-- Per-(Mode, Region) sortedmaps to avoid global scanning
local RunPoolCache = {} -- [Mode .. "|" .. Region] = SortedMap
local MMRStore = DataStoreService:GetDataStore("HiddenMMR#001")

local function GetMMR(UserId: number)
	local Ok, Value = pcall(function()
		return MMRStore:GetAsync(tostring(UserId))
	end)

	if Ok and typeof(Value) == "number" then
		return Value
	end

	return CONFIG.MMR.DefaultMMR
end

local function SetMMR(UserId: number, NewMMR: number)
	pcall(function()
		MMRStore:SetAsync(tostring(UserId), math.floor(NewMMR))
	end)
end

local function DPrint(...)
	if CONFIG.Debug then
		warn("[MM]", ...)
	end
end

local function NowScore()
	return os.time() + (os.clock() % 1)
end

local function GetCapacity(Mode: string)
	return ModeCapacities[Mode] or 5
end

local function IsSpeedrun(Mode: string)
	return Mode == "Speedrun"
end

local function MetricRedirect(Reason: string)
	if not CONFIG.MetricsEnabled then
		return
	end

	if Metrics.Redirects[Reason] ~= nil then
		Metrics.Redirects[Reason] += 1
	end
end

local function MetricFillTime(Mode: string, CreatedAt: number)
	if not CONFIG.MetricsEnabled then
		return
	end

	if typeof(CreatedAt) ~= "number" then
		return
	end

	local Delta = (NowScore()) - CreatedAt
	if Delta < 0 then
		return
	end

	local Bucket = Metrics.FillTimes[Mode]
	if not Bucket then
		Bucket = { Total = 0, Count = 0 }
		Metrics.FillTimes[Mode] = Bucket
	end

	Bucket.Total += Delta
	Bucket.Count += 1
end

function Matchmaking.GetMetrics()
	if not CONFIG.MetricsEnabled then
		return nil
	end

	local Averages = {}
	for Mode, Data in pairs(Metrics.FillTimes) do
		if Data.Count > 0 then
			Averages[Mode] = Data.Total / Data.Count
		end
	end

	return {
		Redirects = table.clone(Metrics.Redirects),
		AverageFillTime = Averages,
	}
end

local function GetRunPlaceId(Mode: string)
	return CONFIG.RunPlaceIds[Mode]
end

local function BroadcastPartyStatus(PartyId: string, Payload)
	if typeof(PartyId) ~= "string" then
		return
	end

	if typeof(Payload) ~= "table" then
		return
	end

	Payload.PartyId = PartyId

	pcall(function()
		MessagingService:PublishAsync(PARTY_TOPIC, Payload)
	end)
end

local function NormalizeRegion(Region: any)
	if typeof(Region) ~= "string" then
		return CONFIG.DefaultRegion
	end

	local R = string.upper(string.gsub(Region, "%s+", ""))

	-- Allow friendly names
	if R == "NORTHAMERICA" or R == "USA" or R == "US" then
		R = "AMERICA"
	elseif R == "EU" then
		R = "EUROPE"
	elseif R == "NA" then
		R = "AMERICA"
	elseif R == "AS" then
		R = "ASIA"
	elseif R == "AF" then
		R = "AFRICA"
	end

	if CONFIG.ValidRegions[R] then
		-- Normalize aliases into canonical names
		if R == "NA" then return "AMERICA" end
		if R == "EU" then return "EUROPE" end
		if R == "AS" then return "ASIA" end
		if R == "AF" then return "AFRICA" end
		return R
	end

	return CONFIG.DefaultRegion
end

local function NormalizeRankTier(Tier: string)
	if Tier == "Diamond" or Tier == "Ascendant" then
		return "DiamondAscendant"
	end
	return Tier
end

-- Region fallback order
local RegionFallbacks = {
	EUROPE = { "EUROPE", "AMERICA", "ASIA", "AFRICA" },
	AMERICA = { "AMERICA", "EUROPE", "ASIA", "AFRICA" },
	ASIA = { "ASIA", "EUROPE", "AMERICA", "AFRICA" },
	AFRICA = { "AFRICA", "EUROPE", "AMERICA", "ASIA" },
}

local function GetFallbackRegions(Mode: string, Region: string)
	local Order = RegionFallbacks[Region] or { Region }

	-- Ranked can try all regions
	if Mode == "Ranked" then
		return Order
	end

	-- Normal / Hardcore: only closest 2 regions
	local Limited = {}
	for i = 1, math.min(2, #Order) do
		Limited[i] = Order[i]
	end

	return Limited
end

local function GetNextRegion(Current: string)
	local Order = RegionFallbacks[Current]
	if not Order then
		return CONFIG.DefaultRegion
	end

	for _, R in ipairs(Order) do
		if R ~= Current then
			return R
		end
	end

	return CONFIG.DefaultRegion
end

local function MakeKey(Mode: string, Region: string, AccessCode: string)
	return tostring(Mode) .. "|" .. tostring(Region) .. "|" .. tostring(AccessCode)
end

local function IsJoinable(Data: any)
	return typeof(Data) == "table"
		and Data.Joinable == true
		and typeof(Data.PlayerCount) == "number"
		and typeof(Data.Capacity) == "number"
		and Data.PlayerCount < Data.Capacity
		and typeof(Data.AccessCode) == "string"
		and typeof(Data.Mode) == "string"
		and typeof(Data.Region) == "string"
end

local function SafePCall(Fn)
	local Ok, Result = pcall(Fn)
	return Ok, Result
end

local function RandomDelay()
	local Min = CONFIG.TeleportRetryMinDelay
	local Max = CONFIG.TeleportRetryMaxDelay
	return Min + math.random() * (Max - Min)
end

-- Ranked penalties helpers
local function Now()
	return os.time()
end

local function CleanExpiredWarnings(Warnings)
	local T = Now()
	local Clean = {}

	for _, W in ipairs(Warnings) do
		if typeof(W) == "table" and typeof(W.Time) == "number" then
			if T - W.Time < CONFIG.RankedWarningExpiry then
				table.insert(Clean, W)
			end
		end
	end

	return Clean
end

local function GetPenalty(UserId: number)
	if not CONFIG.RankedWarningsEnabled then
		return { Warnings = {}, BannedUntil = nil }
	end

	local Ok, Data = pcall(function()
		return RankedPenaltyStore:GetAsync(tostring(UserId))
	end)

	if not Ok or typeof(Data) ~= "table" then
		return { Warnings = {}, BannedUntil = nil }
	end

	Data.Warnings = CleanExpiredWarnings(Data.Warnings or {})

	if typeof(Data.BannedUntil) == "number" and Now() >= Data.BannedUntil then
		Data.BannedUntil = nil
		Data.Warnings = {}
	end

	return Data
end

local function SavePenalty(UserId: number, Data)
	if not CONFIG.RankedWarningsEnabled then
		return
	end

	pcall(function()
		RankedPenaltyStore:SetAsync(tostring(UserId), Data)
	end)
end

function Matchmaking.AddRankedWarning(Player: Player)
	if not CONFIG.RankedWarningsEnabled then
		return
	end

	if not Player then
		return
	end

	local UserId = Player.UserId

	pcall(function()
		RankedPenaltyStore:UpdateAsync(tostring(UserId), function(Old)
			local Data = typeof(Old) == "table" and Old or { Warnings = {}, BannedUntil = nil }

			Data.Warnings = CleanExpiredWarnings(Data.Warnings or {})

			if typeof(Data.BannedUntil) == "number" and Now() >= Data.BannedUntil then
				Data.BannedUntil = nil
				Data.Warnings = {}
			end

			table.insert(Data.Warnings, { Time = Now() })

			if #Data.Warnings >= CONFIG.RankedMaxWarnings then
				Data.BannedUntil = Now() + CONFIG.RankedBanDuration
				Data.Warnings = {}
			end

			return Data
		end)
	end)
end

function Matchmaking.GetRankedPenalty(Player: Player)
	if not Player then
		return nil
	end

	local Data = GetPenalty(Player.UserId)
	local WarnCount = typeof(Data.Warnings) == "table" and #Data.Warnings or 0

	return {
		Warnings = WarnCount,
		MaxWarnings = CONFIG.RankedMaxWarnings,
		BannedUntil = Data.BannedUntil,
	}
end

local function IsRankedBanned(Player: Player)
	if not Player then
		return false
	end

	local Data = GetPenalty(Player.UserId)

	if typeof(Data.BannedUntil) == "number" and Now() < Data.BannedUntil then
		return true
	end

	return false
end

local function GetRunPool(Mode: string, Region: string)
	Region = NormalizeRegion(Region)

	local CacheKey = tostring(Mode) .. "|" .. tostring(Region)
	local Cached = RunPoolCache[CacheKey]
	if Cached then
		return Cached
	end

	local Name = tostring(CONFIG.SortedMapName) .. "|" .. tostring(Mode) .. "|" .. tostring(Region)
	local Pool = MemoryStoreService:GetSortedMap(Name)

	RunPoolCache[CacheKey] = Pool
	return Pool
end

local function GetRankedRunPool(Region: string, RankTier: string)
	Region = NormalizeRegion(Region)
	RankTier = NormalizeRankTier(RankTier)

	local CacheKey = "Ranked|" .. Region .. "|" .. RankTier
	local Cached = RunPoolCache[CacheKey]
	if Cached then
		return Cached
	end

	local Name =
		tostring(CONFIG.SortedMapName)
		.. "|Ranked|"
		.. Region
		.. "|"
		.. RankTier

	local Pool = MemoryStoreService:GetSortedMap(Name)
	RunPoolCache[CacheKey] = Pool
	return Pool
end

local function PublishRun(Mode: string, Region: string, AccessCode: string, Data)
	Region = NormalizeRegion(Region)

	local Pool = GetRunPool(Mode, Region)
	local Key = MakeKey(Mode, Region, AccessCode)

	-- Never rewrite CreatedAt every heartbeat.
	local Score = Data.CreatedAt or NowScore()
	Data.CreatedAt = Score
	Pool:SetAsync(Key, Data, CONFIG.EntryTTL, Score)

	DPrint("Publish:", Key, "PC:", Data.PlayerCount, "/", Data.Capacity, "Joinable:", Data.Joinable)
end

local function RemoveRun(Mode: string, Region: string, AccessCode: string)
	Region = NormalizeRegion(Region)

	local Pool = GetRunPool(Mode, Region)
	local Key = MakeKey(Mode, Region, AccessCode)

	Pool:RemoveAsync(Key)
	DPrint("Remove:", Key)
end

local function TryClaimSlots(
	Mode: string,
	Region: string,
	Key: string,
	Slots: number,
	JoiningMMR: number?
)
	Region = NormalizeRegion(Region)
	Slots = math.max(1, math.floor(Slots))

	local Pool = GetRunPool(Mode, Region)
	local Claimed = nil

	local Ok = pcall(function()
		Pool:UpdateAsync(Key, function(Old)
			if not IsJoinable(Old) then
				return Old
			end

			if Old.PlayerCount + Slots > Old.Capacity then
				return Old
			end

			local OldCount = Old.PlayerCount
			local OldAverage = Old.AverageMMR or CONFIG.MMR.DefaultMMR

			Old.PlayerCount += Slots

			if JoiningMMR then
				local TotalMMR = (OldAverage * OldCount) + (JoiningMMR * Slots)
				Old.AverageMMR = TotalMMR / Old.PlayerCount
			end

			if Old.PlayerCount >= Old.Capacity then
				Old.Joinable = false
				MetricFillTime(Old.Mode, Old.CreatedAt)
			end

			Claimed = Old
			return Old
		end, CONFIG.EntryTTL)
	end)

	if not Ok then
		return nil
	end

	return Claimed
end

local function FindAndClaim(
	Mode: string,
	Region: string,
	Slots: number,
	PlayerMMR: number,
	SearchStartTime: number
)
	Region = NormalizeRegion(Region)
	Slots = math.max(1, math.floor(Slots))

	local Pool = GetRunPool(Mode, Region)

	local Ok, Items = SafePCall(function()
		return Pool:GetRangeAsync(Enum.SortDirection.Ascending, CONFIG.ScanLimit)
	end)

	if not Ok or typeof(Items) ~= "table" then
		return nil
	end

	local Candidates = {}

	local Elapsed = os.clock() - SearchStartTime
	local BaseDelta = CONFIG.MMR.BaseDelta[Mode] or 300
	local Growth = CONFIG.MMR.DeltaGrowthPerSecond[Mode] or 100
	local AllowedDelta = BaseDelta + (Elapsed * Growth)

	for _, Item in ipairs(Items) do
		local Key = Item.key
		local Data = Item.value

		if IsJoinable(Data) then
			local RunMMR = Data.AverageMMR or CONFIG.MMR.DefaultMMR
			local Delta = math.abs(RunMMR - PlayerMMR)

			if Delta <= AllowedDelta then
				table.insert(Candidates, {
					Key = Key,
					Data = Data,
					Delta = Delta,
				})
			end
		end
	end

	table.sort(Candidates, function(a, b)
		return a.Delta < b.Delta
	end)

	for _, Candidate in ipairs(Candidates) do
		local Claimed = TryClaimSlots(
			Mode,
			Region,
			Candidate.Key,
			Slots,
			PlayerMMR
		)

		if Claimed then
			return Claimed
		end
	end

	return nil
end

local function FindAndClaimWithFallback(
	Mode: string,
	Region: string,
	Slots: number,
	PlayerMMR: number,
	SearchStartTime: number
)
	local RegionsToTry = GetFallbackRegions(Mode, Region)

	for _, TryRegion in ipairs(RegionsToTry) do
		local Claimed = FindAndClaim(
			Mode,
			TryRegion,
			Slots,
			PlayerMMR,
			SearchStartTime
		)

		if Claimed then
			return Claimed, TryRegion
		end
	end

	return nil, nil
end

local function FindAndClaimRanked(Region: string, RankTier: string)
	Region = NormalizeRegion(Region)
	RankTier = NormalizeRankTier(RankTier)

	local RegionsToTry = RegionFallbacks[Region] or { Region }

	for _, TryRegion in ipairs(RegionsToTry) do
		local Pool = GetRankedRunPool(TryRegion, RankTier)

		local Ok, Items = SafePCall(function()
			return Pool:GetRangeAsync(Enum.SortDirection.Ascending, CONFIG.ScanLimit)
		end)

		if Ok and typeof(Items) == "table" then
			for _, Item in ipairs(Items) do
				local Key = Item.key
				local Data = Item.value

				if IsJoinable(Data) then
					local Claimed = TryClaimSlots("Ranked", TryRegion, Key, 1)
					if Claimed then
						return Claimed
					end
				end
			end
		end
	end

	return nil
end

local function TeleportToReserved(PlaceId: number, AccessCode: string, PlayerList: { Player }, TeleportData)
	local Attempts = 0
	local MaxAttempts = 1 + (CONFIG.TeleportRetryCount or 0)
	
	if TeleportData.PartyId then
		if not ActiveQueues[TeleportData.PartyId] then
			return false
		end
		
		local MemberUserIds = {}
		for _, P in ipairs(PlayerList) do
			table.insert(MemberUserIds, P.UserId)
		end

		BroadcastPartyStatus(TeleportData.PartyId, {
			State = "Joining",
			Mode = TeleportData.Mode,
			Members = MemberUserIds,
		})
	else
		for _, P in ipairs(PlayerList) do
			if not ActiveQueues[P.UserId] then
				return false
			end
			
			MatchStatus:FireClient(P, {
				State = "Joining",
				Mode = TeleportData.Mode,
			})
		end
	end

	while Attempts < MaxAttempts do
		Attempts += 1

		local Ok = pcall(function()
			local Options = Instance.new("TeleportOptions")
			Options.ReservedServerAccessCode = AccessCode
			Options:SetTeleportData(TeleportData)

			TeleportService:TeleportAsync(
				PlaceId,
				PlayerList,
				Options
			)
		end)

		if Ok then
			if TeleportData.PartyId then
				ActiveQueues[TeleportData.PartyId] = nil
			else
				for _, P in ipairs(PlayerList) do
					ActiveQueues[P.UserId] = nil
				end
			end

			return true
		end

		if Attempts < MaxAttempts then
			task.wait(RandomDelay())
		end
	end

	-- Soft requeue after repeated failure (region fallback)
	if Attempts >= (CONFIG.TeleportFailRequeueThreshold or 2) then
		local NextRegion = GetNextRegion(TeleportData.Region)

		for _, P in ipairs(PlayerList) do
			task.defer(function()
				if TeleportData.Mode == "Ranked" then
					Matchmaking.QueueRanked(P, NextRegion, TeleportData.RankTier)
				else
					Matchmaking.QueuePlayer(P, TeleportData.Mode, NextRegion)
				end
			end)
		end
	end

	return false
end

function Matchmaking.Configure(Overrides)
	if typeof(Overrides) ~= "table" then
		return
	end

	for K, V in pairs(Overrides) do
		CONFIG[K] = V
	end

	RankedPenaltyStore = DataStoreService:GetDataStore(CONFIG.RankedPenaltyStoreName)

	RunPoolCache = {}
end

function Matchmaking.GetModeCapacity(Mode: string)
	return GetCapacity(Mode)
end

function Matchmaking.NormalizeRegion(Region: any)
	return NormalizeRegion(Region)
end

function Matchmaking.QueuePlayer(Player: Player, Mode: string, Region: string)
	if not Player then return false end
	
	ActiveQueues[Player.UserId] = true

	MatchStatus:FireClient(Player, {
		State = "Queued",
		Mode = Mode,
		Region = Region,
	})

	Region = NormalizeRegion(Region)
	
	if IsSpeedrun(Mode) then
		local PlaceId = GetRunPlaceId("Speedrun")
		if typeof(PlaceId) ~= "number" or PlaceId <= 0 then
			return false
		end

		local RunId = HttpService:GenerateGUID(false)

		local Ok, AccessCode = SafePCall(function()
			return TeleportService:ReserveServerAsync(PlaceId)
		end)

		if not Ok or typeof(AccessCode) ~= "string" then
			return false
		end

		local TeleportData = {
			Mode = "Speedrun",
			Region = Region,
			AccessCode = AccessCode,
			Capacity = 1,
			RunId = RunId,
			PartySize = 1,
			Reason = "Speedrun",
			CreatedAt = NowScore(),
		}
		
		MatchStatus:FireClient(Player, {
			State = "Found",
			Mode = Mode,
			Region = Region,
		})

		return TeleportToReserved(PlaceId, AccessCode, { Player }, TeleportData)
	end

	local PlaceId = GetRunPlaceId(Mode)
	if typeof(PlaceId) ~= "number" or PlaceId <= 0 then
		warn("No RunPlaceId configured for mode:", Mode)
		return false
	end

	local Capacity = GetCapacity(Mode)
	local RunId = HttpService:GenerateGUID(false)

	local PlayerMMR = GetMMR(Player.UserId)

	local SearchStart = os.clock()
	local Claimed, FinalRegion

	repeat
		if not ActiveQueues[Player.UserId] then
			return false
		end

		Claimed, FinalRegion = nil, nil

		local RegionsToTry = GetFallbackRegions(Mode, Region)

		for _, TryRegion in ipairs(RegionsToTry) do
			Claimed = FindAndClaim(
				Mode,
				TryRegion,
				1,
				PlayerMMR,
				SearchStart
			)

			if Claimed then
				FinalRegion = TryRegion
				break
			end
		end

		if Claimed then
			break
		end

		task.wait(CONFIG.SearchRetryInterval)
	until os.clock() - SearchStart >= CONFIG.MinSearchTime
	
	Region = FinalRegion or Region
	local AccessCode = Claimed and Claimed.AccessCode or nil
	local CreatedAt = Claimed and Claimed.CreatedAt or nil

	if not AccessCode then
		local Ok, Code = SafePCall(function()
			return TeleportService:ReserveServerAsync(PlaceId)
		end)

		if not Ok or typeof(Code) ~= "string" then
			warn("ReserveServer failed for mode:", Mode)
			return false
		end

		AccessCode = Code
		CreatedAt = NowScore()

		PublishRun(Mode, Region, AccessCode, {
			Mode = Mode,
			Region = Region,
			AccessCode = AccessCode,
			Capacity = Capacity,
			PlayerCount = 1,
			Joinable = true,
			CreatedAt = CreatedAt,
			RunId = RunId,
			AverageMMR = PlayerMMR,
		})
	end

	local TeleportData = {
		Mode = Mode,
		Region = Region,
		AccessCode = AccessCode,
		Capacity = Capacity,
		RunId = RunId,
		PartySize = 1,
		Reason = "Queue",
		CreatedAt = CreatedAt,
	}

	MatchStatus:FireClient(Player, {
		State = "Found",
		Mode = Mode,
		Region = Region,
	})

	return TeleportToReserved(PlaceId, AccessCode, { Player }, TeleportData)
end

function Matchmaking.QueueRanked(Player: Player, Region: string, RankTier: string)
	if not Player then return false end
	if IsRankedBanned(Player) then return false end

	ActiveQueues[Player.UserId] = true

	Region = NormalizeRegion(Region)
	RankTier = NormalizeRankTier(RankTier)

	local PlayerMMR = GetMMR(Player.UserId)

	local PlaceId = GetRunPlaceId("Ranked")
	if typeof(PlaceId) ~= "number" or PlaceId <= 0 then
		return false
	end

	MatchStatus:FireClient(Player, {
		State = "Queued",
		Mode = "Ranked",
		Region = Region,
	})

	local Capacity = GetCapacity("Ranked")
	local RunId = HttpService:GenerateGUID(false)

	local SearchStart = os.clock()
	local Claimed

	repeat
		if not ActiveQueues[Player.UserId] then
			return false
		end

		Claimed = FindAndClaim(
			"Ranked",
			Region,
			1,
			PlayerMMR,
			SearchStart
		)

		if Claimed then
			break
		end

		task.wait(CONFIG.SearchRetryInterval)

	until os.clock() - SearchStart >= CONFIG.MinSearchTime

	local AccessCode = Claimed and Claimed.AccessCode
	local CreatedAt = Claimed and Claimed.CreatedAt

	if not AccessCode then
		local Ok, Code = SafePCall(function()
			return TeleportService:ReserveServerAsync(PlaceId)
		end)

		if not Ok or typeof(Code) ~= "string" then
			return false
		end

		AccessCode = Code
		CreatedAt = NowScore()

		PublishRun("Ranked", Region, AccessCode, {
			Mode = "Ranked",
			Region = Region,
			AccessCode = AccessCode,
			Capacity = Capacity,
			PlayerCount = 1,
			Joinable = true,
			CreatedAt = CreatedAt,
			RunId = RunId,
			AverageMMR = PlayerMMR,
		})
	end

	local TeleportData = {
		Mode = "Ranked",
		Region = Region,
		RankTier = RankTier,
		AccessCode = AccessCode,
		RunId = RunId,
		Capacity = Capacity,
		Reason = "RankedQueue",
		CreatedAt = CreatedAt,
	}

	MatchStatus:FireClient(Player, {
		State = "Found",
		Mode = "Ranked",
		Region = Region,
	})

	return TeleportToReserved(PlaceId, AccessCode, { Player }, TeleportData)
end

local function UpdatePlayerMMR_FFA(
	PlayerUserId: number,
	PlayerPlacement: number,
	TotalPlayers: number,
	LobbyAverageMMR: number,
	KFactor: number?
)
	KFactor = typeof(KFactor) == "number" and KFactor or 32

	if typeof(PlayerUserId) ~= "number" then
		return
	end

	if typeof(PlayerPlacement) ~= "number"
		or typeof(TotalPlayers) ~= "number"
		or TotalPlayers <= 1 then
		return
	end

	-- Convert placement to normalized score (1st = 1, last = 0)
	local ActualScore = 1 - ((PlayerPlacement - 1) / (TotalPlayers - 1))

	-- Safety clamp
	ActualScore = math.clamp(ActualScore, 0, 1)

	pcall(function()
		MMRStore:UpdateAsync(tostring(PlayerUserId), function(OldMMR)
			local PlayerMMR = typeof(OldMMR) == "number"
				and OldMMR
				or CONFIG.MMR.DefaultMMR

			-- Expected score using Elo formula
			local ExpectedScore =
				1 / (1 + 10 ^ ((LobbyAverageMMR - PlayerMMR) / 400))

			-- Elo delta
			local Delta = KFactor * (ActualScore - ExpectedScore)

			local NewMMR = PlayerMMR + Delta

			-- Prevents absurd values
			NewMMR = math.clamp(NewMMR, 0, 5000)

			return math.floor(NewMMR + 0.5)
		end)
	end)
end

function Matchmaking.QueueParty(PartyPlayers: { Player }, Mode: string, Region: string, PartyId: string)
	if typeof(PartyPlayers) ~= "table" or #PartyPlayers <= 0 then
		return false
	end

	if typeof(PartyId) ~= "string" then
		return false
	end
	
	ActiveQueues[PartyId] = true

	Region = NormalizeRegion(Region)

	local PlayerList = {}
	local MemberUserIds = {}

	for _, P in ipairs(PartyPlayers) do
		if typeof(P) == "Instance" and P:IsA("Player") then
			table.insert(PlayerList, P)
			table.insert(MemberUserIds, P.UserId)
		end
	end

	if #PlayerList <= 0 then
		return false
	end

	BroadcastPartyStatus(PartyId, {
		State = "Queued",
		Mode = Mode,
		Region = Region,
		Members = MemberUserIds,
		PartySize = #PlayerList,
	})

	local PlaceId = GetRunPlaceId(Mode)
	if typeof(PlaceId) ~= "number" or PlaceId <= 0 then
		return false
	end

	local Capacity = GetCapacity(Mode)
	local PartySize = #PlayerList

	if PartySize > Capacity then
		return false
	end

	local RunId = HttpService:GenerateGUID(false)

	local SearchStart = os.clock()
	local Claimed, FinalRegion
	
	local TotalMMR = 0
	for _, P in ipairs(PlayerList) do
		TotalMMR += GetMMR(P.UserId)
	end

	local PartyAverageMMR = TotalMMR / #PlayerList

	repeat
		if not ActiveQueues[PartyId] then
			return false
		end

		Claimed, FinalRegion = FindAndClaimWithFallback(
			Mode,
			Region,
			PartySize,
			PartyAverageMMR,
			SearchStart
		)

		if Claimed then
			break
		end

		task.wait(CONFIG.SearchRetryInterval)
	until os.clock() - SearchStart >= CONFIG.MinSearchTime
	
	Region = FinalRegion or Region
	local AccessCode = Claimed and Claimed.AccessCode
	local CreatedAt = Claimed and Claimed.CreatedAt

	if not AccessCode then
		local Ok, Code = SafePCall(function()
			return TeleportService:ReserveServerAsync(PlaceId)
		end)

		if not Ok or typeof(Code) ~= "string" then
			return false
		end

		AccessCode = Code
		CreatedAt = NowScore()

		PublishRun(Mode, Region, AccessCode, {
			Mode = Mode,
			Region = Region,
			AccessCode = AccessCode,
			Capacity = Capacity,
			PlayerCount = PartySize,
			Joinable = PartySize < Capacity,
			CreatedAt = CreatedAt,
			RunId = RunId,
			AverageMMR = PartyAverageMMR
		})
	end

	BroadcastPartyStatus(PartyId, {
		State = "Found",
		Mode = Mode,
		Region = Region,
		Members = MemberUserIds,
		PartySize = PartySize,
	})

	local TeleportData = {
		Mode = Mode,
		Region = Region,
		AccessCode = AccessCode,
		Capacity = Capacity,
		RunId = RunId,
		PartySize = PartySize,
		PartyId = PartyId,
		Reason = "QueueParty",
		CreatedAt = CreatedAt,
	}

	return TeleportToReserved(PlaceId, AccessCode, PlayerList, TeleportData)
end

function Matchmaking.AllocatePartyRun(
	Mode: string,
	Region: string,
	PartySize: number,
	IsPrivate: boolean?
)
	if typeof(Mode) ~= "string" or typeof(PartySize) ~= "number" then
		return nil
	end

	Region = NormalizeRegion(Region)
	PartySize = math.max(1, math.floor(PartySize))
	IsPrivate = IsPrivate == true

	local PlaceId = GetRunPlaceId(Mode)
	if typeof(PlaceId) ~= "number" or PlaceId <= 0 then
		return nil
	end

	local Capacity = GetCapacity(Mode)
	if PartySize > Capacity then
		return nil
	end

	local RunId = HttpService:GenerateGUID(false)

	if IsPrivate then
		local Ok, AccessCode = SafePCall(function()
			return TeleportService:ReserveServerAsync(PlaceId)
		end)

		if not Ok or typeof(AccessCode) ~= "string" then
			return nil
		end

		return {
			PlaceId = PlaceId,
			AccessCode = AccessCode,
			RunId = RunId,
			Region = Region,
			Capacity = Capacity,
			IsPrivate = true,
		}
	end

	local Claimed, FinalRegion
	
	local SearchStart = os.clock()
	local DefaultMMR = CONFIG.MMR.DefaultMMR

	repeat
		Claimed, FinalRegion = FindAndClaimWithFallback(
			Mode,
			Region,
			PartySize,
			DefaultMMR,
			SearchStart
		)

		if Claimed then
			break
		end

		task.wait(CONFIG.SearchRetryInterval)
	until os.clock() - SearchStart >= CONFIG.MinSearchTime

	Region = FinalRegion or Region

	local AccessCode = Claimed and Claimed.AccessCode
	local CreatedAt = Claimed and Claimed.CreatedAt

	if not AccessCode then
		local Ok, Code = SafePCall(function()
			return TeleportService:ReserveServerAsync(PlaceId)
		end)

		if not Ok or typeof(Code) ~= "string" then
			return nil
		end

		AccessCode = Code
		CreatedAt = NowScore()

		PublishRun(Mode, Region, AccessCode, {
			Mode = Mode,
			Region = Region,
			AccessCode = AccessCode,
			Capacity = Capacity,
			PlayerCount = PartySize,
			Joinable = PartySize < Capacity,
			CreatedAt = CreatedAt,
			RunId = RunId,
			AverageMMR = CONFIG.MMR.DefaultMMR
		})
	end

	return {
		PlaceId = PlaceId,
		AccessCode = AccessCode,
		RunId = RunId,
		Region = Region,
		Capacity = Capacity,
		IsPrivate = false,
	}
end

local function SafeGetTeleportData(Player: Player)
	local Ok, JoinData = SafePCall(function()
		return Player:GetJoinData()
	end)

	if not Ok or not JoinData then
		return nil
	end

	return JoinData.TeleportData
end

function Matchmaking.GetRunInfo()
	for _, P in ipairs(Players:GetPlayers()) do
		local Data = SafeGetTeleportData(P)
		if typeof(Data) == "table" and typeof(Data.AccessCode) == "string" then
			return Data
		end
	end
	return nil
end

function Matchmaking.HostBeginJoinable(Mode: string, Region: string, AccessCode: string, Capacity: number, RunId: string?)
	if typeof(Mode) ~= "string" or typeof(Region) ~= "string" or typeof(AccessCode) ~= "string" then
		return
	end

	Region = NormalizeRegion(Region)
	Capacity = typeof(Capacity) == "number" and Capacity or GetCapacity(Mode)

	local Alive = true
	local CreatedAt = NowScore()

	for _, P in ipairs(Players:GetPlayers()) do
		local TD = SafeGetTeleportData(P)
		if typeof(TD) == "table" then
			if typeof(TD.CreatedAt) == "number" then
				CreatedAt = TD.CreatedAt
			end
			if typeof(TD.RunId) == "string" and (RunId == nil or RunId == "") then
				RunId = TD.RunId
			end
			break
		end
	end

	local function Publish()
		if not Alive then
			return
		end

		local Count = #Players:GetPlayers()

		if Count >= Capacity then
			Alive = false
			RemoveRun(Mode, Region, AccessCode)
			return
		end

		local Buffer = typeof(CONFIG.AdvertiseBufferSlots) == "number" and CONFIG.AdvertiseBufferSlots or 0
		Buffer = math.max(0, math.floor(Buffer))

		local AdvertisedCount = math.min(Capacity, Count + Buffer)
		local Joinable = AdvertisedCount < Capacity

		local ExistingMMR = nil

		local Pool = GetRunPool(Mode, Region)
		local Key = MakeKey(Mode, Region, AccessCode)

		local Ok, OldData = SafePCall(function()
			return Pool:GetAsync(Key)
		end)

		if Ok and typeof(OldData) == "table" then
			ExistingMMR = OldData.AverageMMR
		end

		PublishRun(Mode, Region, AccessCode, {
			Mode = Mode,
			Region = Region,
			AccessCode = AccessCode,
			Capacity = Capacity,
			PlayerCount = AdvertisedCount,
			Joinable = Joinable,
			CreatedAt = CreatedAt,
			RunId = RunId,
			AverageMMR = ExistingMMR or CONFIG.MMR.DefaultMMR
		})

		if not Joinable then
			Alive = false
			RemoveRun(Mode, Region, AccessCode)
		end
	end

	Publish()

	task.spawn(function()
		while Alive and RunService:IsRunning() do
			task.wait(CONFIG.HeartbeatInterval)
			Publish()
		end
	end)
end

function Matchmaking.HostLockRun(Mode: string, Region: string, AccessCode: string)
	if typeof(Mode) ~= "string" or typeof(Region) ~= "string" or typeof(AccessCode) ~= "string" then
		return
	end

	Region = NormalizeRegion(Region)
	RemoveRun(Mode, Region, AccessCode)
end

function Matchmaking.HostValidatePlayer(Player: Player, RunStarted: boolean, Info)
	if not Player or typeof(Info) ~= "table" then
		return
	end

	local Mode = Info.Mode
	local Region = NormalizeRegion(Info.Region)
	local Capacity = Info.Capacity or GetCapacity(Mode)
	local ExpectedRunId = Info.RunId

	local function Redirect(Reason: string)
		MetricRedirect(Reason)

		task.defer(function()
			Matchmaking.QueuePlayer(Player, Mode, Region)
		end)
	end

	if #Players:GetPlayers() > Capacity then
		Redirect("OverCapacity")
		return
	end

	if RunStarted then
		Redirect("RunStarted")
		return
	end

	if typeof(ExpectedRunId) == "string" and ExpectedRunId ~= "" then
		local TD = SafeGetTeleportData(Player)
		if typeof(TD) ~= "table" or TD.RunId ~= ExpectedRunId then
			Redirect("RunIdMismatch")
			return
		end
	end
end

function Matchmaking.CancelQueue(Player: Player, PartyId: string?)
	if not Player then
		return
	end

	if typeof(PartyId) == "string" then
		ActiveQueues[PartyId] = nil

		BroadcastPartyStatus(PartyId, {
			State = "Cancelled",
			CancelledBy = Player.UserId,
		})
		return
	end

	ActiveQueues[Player.UserId] = nil

	MatchStatus:FireClient(Player, {
		State = "Cancelled",
	})
end

TeleportService.TeleportInitFailed:Connect(function(Player, Result, ErrorMessage)
	local TD = Player:GetJoinData()
	local TeleportData = TD and TD.TeleportData

	if TeleportData and TeleportData.PartyId then
		BroadcastPartyStatus(TeleportData.PartyId, {
			State = "Failed",
			Members = { Player.UserId },
		})
	else
		MatchStatus:FireClient(Player, {
			State = "Failed",
			Result = tostring(Result),
			Error = tostring(ErrorMessage),
		})
	end
end)

if not RunService:IsStudio() then
	pcall(function()
		MessagingService:SubscribeAsync(PARTY_TOPIC, function(Message)
			local Data = Message.Data
			if typeof(Data) ~= "table" then
				return
			end

			local Members = Data.Members
			if typeof(Members) ~= "table" then
				return
			end

			for _, UserId in ipairs(Members) do
				local Player = Players:GetPlayerByUserId(UserId)
				if Player then
					MatchStatus:FireClient(Player, Data)
				end
			end
		end)
	end)
end

return Matchmaking
