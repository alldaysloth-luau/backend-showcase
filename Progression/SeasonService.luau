local SeasonService = {}

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local ProfileService = require(ServerStorage.Modules.ProfileService)

local Config = {
	ActiveSeasonId = "S1", -- 23 Feb -> 23 April (2 Months)

	StartTimeUtc = 1771804800,
	EndTimeUtc = 1776902400, -- 59 days

	Tiers = 40,
	XPPerTier = 175,

	WeekendBonusMultiplier = 2,

	Daily = {
		LoginXP = 50,
		FirstRunXP = 50,
		FirstWinXP = 50,

		CapXP = 150,
	},

	Bonus = {
		Room10XP = 25,
		Room20XP = 25,
		PerfectStreakXP = 25,

		DailyCapXP = 75,
	},

	Rewards = {
		Free = {
			[1] = { Type = "Currency", Amount = 200 },
			[3] = { Type = "Currency", Amount = 250 },
			[5] = { Type = "Currency", Amount = 300 },
			[7] = { Type = "Aura", Id = "Blue Trail" },
			[9] = { Type = "Currency", Amount = 500 },
		},
		Premium = {
			[1] = { Type = "Skin", Id = "Neon Edge" },
			[2] = { Type = "Currency", Amount = 500 },
			[3] = { Type = "Emote", Id = "Victory Pose" },
			[4] = { Type = "Character", Id = "Cipher" },
			[5] = {  Type = "Currency", Amount = 750 },	
		},
	},
}
SeasonService.Config = Config

local State = {
	Started = false,
}

local function Clamp(n, a, b)
	if n < a then return a end
	if n > b then return b end
	return n
end

local function UtcNow()
	return os.time(os.date("!*t"))
end

local function DayKeyUtc(TimeUtc: number): number
	local t = os.date("!*t", TimeUtc)
	return (t.year * 1000) + t.yday
end

local function IsWeekendUtc(TimeUtc: number): boolean
	local t = os.date("!*t", TimeUtc)
	return t.wday == 1 or t.wday == 7
end

local function EnsureRewardsShape()
	if typeof(Config.Rewards) ~= "table" then
		Config.Rewards = { Free = {}, Premium = {} }
	end
	Config.Rewards.Free = Config.Rewards.Free or {}
	Config.Rewards.Premium = Config.Rewards.Premium or {}
end

local function GetSeasonProgress(SeasonData)
	local XP = SeasonData.XP or 0
	local Tier = math.floor(XP / Config.XPPerTier) + 1
	Tier = Clamp(Tier, 1, Config.Tiers + 1)

	local Into = XP % Config.XPPerTier
	local Remaining = Config.XPPerTier - Into

	if Tier > Config.Tiers then
		Into = Config.XPPerTier
		Remaining = 0
	end

	return Tier, Into, Remaining
end

local function EnsureSeasonData(Profile)
	Profile.Seasons = Profile.Seasons or {}

	local Season = Profile.Seasons[Config.ActiveSeasonId]
	if not Season then
		Season = {
			SeasonId = Config.ActiveSeasonId,
			XP = 0,

			ClaimedFree = {},
			ClaimedPremium = {},

			Daily = {
				DayKey = 0,
				EarnedXP = 0,
				BonusEarnedXP = 0,
				DidLogin = false,
				DidFirstRun = false,
				DidFirstWin = false,
			},

			PurchasedPremium = false,
		}

		Profile.Seasons[Config.ActiveSeasonId] = Season
	end

	Season.ClaimedFree = Season.ClaimedFree or {}
	Season.ClaimedPremium = Season.ClaimedPremium or {}

	Season.Daily = Season.Daily or {}
	Season.Daily.DayKey = Season.Daily.DayKey or 0
	Season.Daily.EarnedXP = Season.Daily.EarnedXP or 0
	Season.Daily.BonusEarnedXP = Season.Daily.BonusEarnedXP or 0
	Season.Daily.DidLogin = Season.Daily.DidLogin or false
	Season.Daily.DidFirstRun = Season.Daily.DidFirstRun or false
	Season.Daily.DidFirstWin = Season.Daily.DidFirstWin or false

	if Season.PurchasedPremium == nil then
		Season.PurchasedPremium = false
	end

	return Season
end

local function ResetDailyIfNeeded(SeasonData, NowUtc: number)
	local Key = DayKeyUtc(NowUtc)
	if SeasonData.Daily.DayKey ~= Key then
		SeasonData.Daily.DayKey = Key
		SeasonData.Daily.EarnedXP = 0
		SeasonData.Daily.BonusEarnedXP = 0
		SeasonData.Daily.DidLogin = false
		SeasonData.Daily.DidFirstRun = false
		SeasonData.Daily.DidFirstWin = false
	end
end

local function CanEarnSeasonXP(NowUtc: number): boolean
	if Config.StartTimeUtc > 0 and NowUtc < Config.StartTimeUtc then
		return false
	end
	if Config.EndTimeUtc > 0 and NowUtc >= Config.EndTimeUtc then
		return false
	end
	return true
end

local function ApplyWeekendBonus(NowUtc: number, Amount: number): number
	if Amount <= 0 then return 0 end
	if Config.WeekendBonusMultiplier and Config.WeekendBonusMultiplier > 1 then
		if IsWeekendUtc(NowUtc) then
			return math.floor(Amount * Config.WeekendBonusMultiplier)
		end
	end
	return Amount
end

local function AwardSeasonXP(Profile, SeasonData, Amount: number, IsBonus: boolean?)
	if Amount <= 0 then return 0 end

	local NowUtc = UtcNow()
	if not CanEarnSeasonXP(NowUtc) then
		return 0
	end

	ResetDailyIfNeeded(SeasonData, NowUtc)

	local AmountWithBonus = ApplyWeekendBonus(NowUtc, Amount)

	local DailyCap = Config.Daily.CapXP or 0
	local BonusCap = Config.Bonus.DailyCapXP or 0

	if IsBonus then
		if BonusCap > 0 then
			local Remaining = BonusCap - (SeasonData.Daily.BonusEarnedXP or 0)
			if Remaining <= 0 then
				return 0
			end
			AmountWithBonus = math.min(AmountWithBonus, Remaining)
		end

		SeasonData.Daily.BonusEarnedXP = (SeasonData.Daily.BonusEarnedXP or 0) + AmountWithBonus
	else
		if DailyCap > 0 then
			local Remaining = DailyCap - (SeasonData.Daily.EarnedXP or 0)
			if Remaining <= 0 then
				return 0
			end
			AmountWithBonus = math.min(AmountWithBonus, Remaining)
		end

		SeasonData.Daily.EarnedXP = (SeasonData.Daily.EarnedXP or 0) + AmountWithBonus
	end

	local MaxXP = Config.Tiers * Config.XPPerTier
	SeasonData.XP = Clamp((SeasonData.XP or 0) + AmountWithBonus, 0, MaxXP)

	return AmountWithBonus
end

local function GetProfile(Player: Player)
	return ProfileService.GetProfile(Player)
end

function SeasonService.Configure(NewConfig)
	if typeof(NewConfig) ~= "table" then
		return
	end

	for k, v in pairs(NewConfig) do
		Config[k] = v
	end

	EnsureRewardsShape()
end

function SeasonService.GetActiveSeasonId()
	return Config.ActiveSeasonId
end

function SeasonService.GetSeasonWindow()
	return Config.StartTimeUtc, Config.EndTimeUtc
end

function SeasonService.GetPlayerSeason(Player: Player)
	local Profile = GetProfile(Player)
	if not Profile then
		return nil
	end

	local SeasonData = EnsureSeasonData(Profile)
	local NowUtc = UtcNow()
	ResetDailyIfNeeded(SeasonData, NowUtc)

	local Tier, Into, Remaining = GetSeasonProgress(SeasonData)

	return {
		SeasonId = Config.ActiveSeasonId,
		XP = SeasonData.XP or 0,
		Tier = Tier,
		IntoTierXP = Into,
		RemainingInTierXP = Remaining,
		MaxTier = Config.Tiers,

		Daily = {
			DayKey = SeasonData.Daily.DayKey,
			EarnedXP = SeasonData.Daily.EarnedXP,
			BonusEarnedXP = SeasonData.Daily.BonusEarnedXP,
			DidLogin = SeasonData.Daily.DidLogin,
			DidFirstRun = SeasonData.Daily.DidFirstRun,
			DidFirstWin = SeasonData.Daily.DidFirstWin,
		},

		PurchasedPremium = SeasonData.PurchasedPremium == true,
	}
end

function SeasonService.HasPremium(Player: Player): boolean
	local Profile = GetProfile(Player)
	if not Profile then
		return false
	end

	local SeasonData = EnsureSeasonData(Profile)
	return SeasonData.PurchasedPremium == true
end

function SeasonService.SetPremium(Player: Player, Enabled: boolean)
	local Profile = GetProfile(Player)
	if not Profile then
		return false
	end

	local SeasonData = EnsureSeasonData(Profile)
	SeasonData.PurchasedPremium = Enabled == true

	ProfileService.Save(Player)
	return true
end

function SeasonService.AwardDailyLogin(Player: Player)
	local Profile = GetProfile(Player)
	if not Profile then return 0 end

	local SeasonData = EnsureSeasonData(Profile)
	local NowUtc = UtcNow()
	ResetDailyIfNeeded(SeasonData, NowUtc)

	if SeasonData.Daily.DidLogin then
		return 0
	end

	SeasonData.Daily.DidLogin = true

	local Awarded = AwardSeasonXP(Profile, SeasonData, Config.Daily.LoginXP, false)
	return Awarded
end

function SeasonService.AwardFirstRunOfDay(Player: Player)
	local Profile = GetProfile(Player)
	if not Profile then return 0 end

	local SeasonData = EnsureSeasonData(Profile)
	local NowUtc = UtcNow()
	ResetDailyIfNeeded(SeasonData, NowUtc)

	if SeasonData.Daily.DidFirstRun then
		return 0
	end

	SeasonData.Daily.DidFirstRun = true

	local Awarded = AwardSeasonXP(Profile, SeasonData, Config.Daily.FirstRunXP, false)
	return Awarded
end

function SeasonService.AwardFirstWinOfDay(Player: Player)
	local Profile = GetProfile(Player)
	if not Profile then return 0 end

	local SeasonData = EnsureSeasonData(Profile)
	local NowUtc = UtcNow()
	ResetDailyIfNeeded(SeasonData, NowUtc)

	if SeasonData.Daily.DidFirstWin then
		return 0
	end

	SeasonData.Daily.DidFirstWin = true

	local Awarded = AwardSeasonXP(Profile, SeasonData, Config.Daily.FirstWinXP, false)
	return Awarded
end

function SeasonService.AwardBonus(Player: Player, BonusKey: string)
	local Profile = GetProfile(Player)
	if not Profile then return 0 end

	local SeasonData = EnsureSeasonData(Profile)

	local Amount = 0
	if BonusKey == "Room10" then
		Amount = Config.Bonus.Room10XP or 0
	elseif BonusKey == "Room20" then
		Amount = Config.Bonus.Room20XP or 0
	elseif BonusKey == "PerfectStreak" then
		Amount = Config.Bonus.PerfectStreakXP or 0
	end

	local Awarded = AwardSeasonXP(Profile, SeasonData, Amount, true)
	return Awarded
end

function SeasonService.CanClaimTier(Player: Player, Tier: number, Track: string)
	local Profile = GetProfile(Player)
	if not Profile then
		return false, "NoProfile"
	end

	if typeof(Tier) ~= "number" or Tier < 1 or Tier > Config.Tiers then
		return false, "BadTier"
	end

	local SeasonData = EnsureSeasonData(Profile)
	local TierNow = GetSeasonProgress(SeasonData)

	if Tier > TierNow then
		return false, "NotUnlocked"
	end

	if Track == "Premium" then
		if SeasonData.PurchasedPremium ~= true then
			return false, "NoPremium"
		end

		if SeasonData.ClaimedPremium[Tier] then
			return false, "AlreadyClaimed"
		end

		return true
	end

	if Track == "Free" then
		if SeasonData.ClaimedFree[Tier] then
			return false, "AlreadyClaimed"
		end

		return true
	end

	return false, "BadTrack"
end

function SeasonService.ClaimTier(Player: Player, Tier: number, Track: string)
	local Profile = GetProfile(Player)
	if not Profile then
		return false, "NoProfile"
	end

	local Ok, Reason = SeasonService.CanClaimTier(Player, Tier, Track)
	if not Ok then
		return false, Reason
	end

	EnsureRewardsShape()

	local Reward
	if Track == "Premium" then
		Reward = Config.Rewards.Premium[Tier]
	else
		Reward = Config.Rewards.Free[Tier]
	end

	if not Reward then
		Reward = { Type = "None" }
	end

	if Reward.Type ~= "None" then
		local Granted = ProfileService.GrantReward(Player, Reward)
		if not Granted then
			return false, "GrantFailed"
		end
	end

	local SeasonData = EnsureSeasonData(Profile)

	if Track == "Premium" then
		SeasonData.ClaimedPremium[Tier] = true
	else
		SeasonData.ClaimedFree[Tier] = true
	end

	ProfileService.Save(Player)

	return true
end

function SeasonService.GetTierReward(Tier: number)
	EnsureRewardsShape()

	return {
		Free = Config.Rewards.Free[Tier],
		Premium = Config.Rewards.Premium[Tier],
	}
end

function SeasonService.GetTimeline()
	local NowUtc = UtcNow()
	local StartUtc = Config.StartTimeUtc
	local EndUtc = Config.EndTimeUtc

	local Active = CanEarnSeasonXP(NowUtc)
	local Remaining = 0
	if EndUtc and EndUtc > 0 then
		Remaining = math.max(0, EndUtc - NowUtc)
	end

	return {
		SeasonId = Config.ActiveSeasonId,
		NowUtc = NowUtc,
		StartTimeUtc = StartUtc,
		EndTimeUtc = EndUtc,
		IsActive = Active,
		RemainingSeconds = Remaining,
	}
end

function SeasonService.Start()
	if State.Started then
		return
	end
	State.Started = true

	for k,v in pairs(Config.Rewards.Free) do
		print(k)
	end

	EnsureRewardsShape()

	for _, Player in ipairs(Players:GetPlayers()) do
		local Profile = GetProfile(Player)
		if Profile then
			local SeasonData = EnsureSeasonData(Profile)
			ResetDailyIfNeeded(SeasonData, UtcNow())
		end
	end
end

return SeasonService
