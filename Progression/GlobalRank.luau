local DataStoreService = game:GetService("DataStoreService")

local Season = "Season: 1"

local RankedStore = DataStoreService:GetOrderedDataStore("RankedMMR" .. Season)
local MetaStore = DataStoreService:GetDataStore("RankedMeta" .. Season)

local RankedCountKey = "TotalRankedPlayers"

local Page_Delay = 0.1
local Worker_Count = 4

local Retry_Base = 1
local Retry_Max = 30

local LeaderboardCache = {}

local SnapshotRunning = false
local SnapshotLoaded = false

local function RetryWithBackoff(Func)
	local Attempt = 0
	
	while true do
		local Success, Result = pcall(Func)
		
		if Success then
			return Result
		end
		
		Attempt += 1
		local Backoff = math.min(Retry_Base * (2 ^ Attempt), Retry_Max)
		Backoff += math.random() * 0.5
		
		task.wait(Backoff)
	end
end

local function Worker(StartOffset, TotalPlayers)
	local Pages = RetryWithBackoff(function()
		return RankedStore:GetSortedAsync(false, 100)
	end)

	local RankPosition = 0
	local PageIndex = 0

	while true do
		local Page = Pages:GetCurrentPage()
		PageIndex += 1

		-- Only process pages assigned to this worker
		if PageIndex % Worker_Count == StartOffset then
			for _, Entry in ipairs(Page) do
				RankPosition += 1
				local UserId = tonumber(Entry.key)
				local Percentile = 1 - ((RankPosition - 1) / TotalPlayers)
				LeaderboardCache[UserId] = {RankPosition, Percentile}
			end
		else
			RankPosition += #Page
		end

		if Pages.IsFinished then
			break
		end

		task.wait(Page_Delay)

		RetryWithBackoff(function()
			Pages:AdvanceToNextPageAsync()
		end)
	end
end

local function BuildLeaderboardSnapshot()
	if SnapshotRunning then
		return
	end

	SnapshotRunning = true

	local TotalPlayers = RetryWithBackoff(function()
		return MetaStore:GetAsync(RankedCountKey)
	end)

	local Workers = math.min(Worker_Count, math.max(1, math.floor(TotalPlayers / 100)))

	local Threads = {}

	for i = 0, Workers - 1 do
		Threads[i] = task.spawn(function()
			Worker(i, TotalPlayers)
		end)
	end

	for i = 0, Workers - 1 do
		task.wait()
	end

	SnapshotLoaded = true
	SnapshotRunning = false
end

local function UpdateRanking(UserId: number, Score: number)
	local WasNew = false
	local Key = tostring(UserId)

	local Success = pcall(function()
		RankedStore:UpdateAsync(Key, function(Old)
			if Old == nil then
				WasNew = true
			end
			
			return Score
		end)
	end)

	if not Success then
		return
	end

	if WasNew then
		pcall(function()
			MetaStore:UpdateAsync(RankedCountKey, function(Old)
				return (Old or 0) + 1
			end)
		end)
	end
end

local function UpdateGlobalScore(
	UserId: number,
	Wins: number,
	Losses: number,
	PerfectRooms: number,
	CurrentStreak: number
): number

	local TotalMatches = Wins + Losses
	if TotalMatches <= 0 then
		return 0
	end

	local WinRate = Wins / TotalMatches
	local WinRateFactor = WinRate * (1 - math.exp(-TotalMatches / 50))

	local LogWins = math.log(Wins + 1)

	local PerfectRate = PerfectRooms / TotalMatches
	local PerfectRateFactor =
		PerfectRate * (1 - math.exp(-TotalMatches / 40))

	local CappedStreak = math.min(CurrentStreak, 25)
	local StreakFactor = math.sqrt(CappedStreak)

	local Score =
		(WinRateFactor * 1000)
		+ (LogWins * 150)
		+ (PerfectRateFactor * 600)
		+ (StreakFactor * 50)

	UpdateRanking(UserId, Score)

	return Score
end

local function GetGlobalScore(UserId: number)
	if not SnapshotLoaded then
		task.spawn(BuildLeaderboardSnapshot)
	end

	local Data = LeaderboardCache[UserId]

	if not Data then
		return nil, nil
	end

	return Data[1], Data[2]
end

return {
	UpdateGlobalScore = UpdateGlobalScore,
	GetGlobalScore = GetGlobalScore
}
