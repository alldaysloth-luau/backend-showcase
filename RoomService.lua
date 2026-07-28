local RoomService = {}

local Players = game:GetService("Players")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local Matchmaking = require(ServerStorage:WaitForChild("Modules"):WaitForChild("Matchmaker"))

local CONFIG = {
	RoomStoreName = "RoomStore#002",
	RoomTTL = 120,
	LeaderTimeout = 30,
	PingInterval = 10,
	MaxMembers = 5,
	Debug = false,
}

local ROOM_TOPIC = "RoomEvent#003"

local RoomStore = MemoryStoreService:GetSortedMap(CONFIG.RoomStoreName)
local ActiveLeaderPings = {}

local function DPrint(...)
	if CONFIG.Debug then
		warn("[ROOM]", ...)
	end
end

local function Now()
	return os.time()
end

local function GenerateRoomId()
	return string.sub(HttpService:GenerateGUID(false), 1, 6):upper()
end

local function IsRoomAlive(Room)
	if typeof(Room) ~= "table" then
		return false
	end

	if typeof(Room.LeaderLastPing) ~= "number" then
		return false
	end

	if Now() - Room.LeaderLastPing > CONFIG.LeaderTimeout then
		return false
	end

	return true
end

local function PublishRoom(RoomId, Data)
	if not Data then return end
	RoomStore:SetAsync(RoomId, Data, CONFIG.RoomTTL, Data.CreatedAt or Now())
end

local function RemoveRoom(RoomId)
	pcall(function()
		RoomStore:RemoveAsync(RoomId)
	end)
end

local function Broadcast(RoomId, Payload)
	if typeof(Payload) ~= "table" then
		return
	end

	Payload.RoomId = RoomId

	pcall(function()
		MessagingService:PublishAsync(ROOM_TOPIC, Payload)
	end)
end

function RoomService.CreateRoom(Player, Mode, Region)
	if not Player then return nil end

	local RoomId = GenerateRoomId()

	local Data = {
		RoomId = RoomId,
		Leader = Player.UserId,
		Members = { Player.UserId },
		Mode = Mode,
		Region = Region,
		Joinable = true,
		Locked = false,
		CreatedAt = Now(),
		LeaderLastPing = Now(),
	}

	PublishRoom(RoomId, Data)

	DPrint("Room created:", RoomId)

	return RoomId
end

function RoomService.PingRoom(Player, RoomId)
	if not Player or typeof(RoomId) ~= "string" then
		return
	end

	pcall(function()
		RoomStore:UpdateAsync(RoomId, function(Room)
			if typeof(Room) ~= "table" then
				return nil
			end

			if Room.Leader ~= Player.UserId then
				return Room
			end

			Room.LeaderLastPing = Now()
			return Room
		end, CONFIG.RoomTTL)
	end)
end

function RoomService.JoinRoom(Player, RoomId)
	if not Player or typeof(RoomId) ~= "string" then
		return false
	end

	local Joined = false
	local Destroyed = false

	pcall(function()
		RoomStore:UpdateAsync(RoomId, function(Room)
			if typeof(Room) ~= "table" then
				return nil
			end

			if not IsRoomAlive(Room) then
				Destroyed = true
				return nil
			end

			if not Room.Joinable then
				return Room
			end
			
			if Room.Locked then
				return Room
			end

			if #Room.Members >= CONFIG.MaxMembers then
				return Room
			end

			for _, UserId in ipairs(Room.Members) do
				if UserId == Player.UserId then
					Joined = true
					return Room
				end
			end

			table.insert(Room.Members, Player.UserId)
			Joined = true
			return Room
		end, CONFIG.RoomTTL)
	end)

	if Destroyed then
		RemoveRoom(RoomId)
		return false
	end

	if Joined then
		Broadcast(RoomId, {
			Type = "Joined",
			UserId = Player.UserId,
		})
	end

	return Joined
end

function RoomService.LeaveRoom(Player, RoomId)
	if not Player then return end

	local DestroyRoom = false

	pcall(function()
		RoomStore:UpdateAsync(RoomId, function(Room)
			if typeof(Room) ~= "table" then
				return nil
			end

			if not IsRoomAlive(Room) then
				DestroyRoom = true
				return nil
			end

			local NewMembers = {}

			for _, UserId in ipairs(Room.Members) do
				if UserId ~= Player.UserId then
					table.insert(NewMembers, UserId)
				end
			end

			Room.Members = NewMembers

			if Player.UserId == Room.Leader or #Room.Members == 0 then
				DestroyRoom = true
				return nil
			end

			return Room
		end, CONFIG.RoomTTL)
	end)

	if DestroyRoom then
		RemoveRoom(RoomId)
		Broadcast(RoomId, {
			Type = "Destroyed",
		})
	end
end

function RoomService.StartQueue(Player, RoomId)
	if not Player then return false end

	local Room
	local Ok = pcall(function()
		Room = RoomStore:GetAsync(RoomId)
	end)

	if not Ok or typeof(Room) ~= "table" then
		return false
	end

	if not IsRoomAlive(Room) then
		RemoveRoom(RoomId)
		return false
	end

	if Player.UserId ~= Room.Leader then
		return false
	end

	local PlayerList = {}

	for _, UserId in ipairs(Room.Members) do
		local P = Players:GetPlayerByUserId(UserId)
		if P then
			table.insert(PlayerList, P)
		end
	end

	if #PlayerList <= 0 then
		return false
	end

	Matchmaking.QueueParty(
		PlayerList,
		Room.Mode,
		Room.Region,
		Room.RoomId
	)

	Broadcast(RoomId, {
		Type = "Queued",
	})

	return true
end

function RoomService.GetRoom(RoomId)
	if typeof(RoomId) ~= "string" then
		return nil
	end

	local Ok, Room = pcall(function()
		return RoomStore:GetAsync(RoomId)
	end)

	if not Ok or typeof(Room) ~= "table" then
		return nil
	end

	if not IsRoomAlive(Room) then
		RemoveRoom(RoomId)
		return nil
	end

	return Room
end

function RoomService.StartPublicQueue(Player, RoomId)
	if not Player then
		return false
	end

	local Room = RoomService.GetRoom(RoomId)
	if not Room then
		return false
	end

	if Player.UserId ~= Room.Leader then
		return false
	end

	local PartySize = #Room.Members

	local Allocation = Matchmaking.AllocatePartyRun(
		Room.Mode,
		Room.Region,
		PartySize
	)

	if not Allocation then
		return false
	end

	Broadcast(RoomId, {
		Type = "QueueStart",
		Mode = Room.Mode,
		Region = Allocation.Region,
		AccessCode = Allocation.AccessCode,
		RunId = Allocation.RunId,
		Capacity = Allocation.Capacity,
		PlaceId = Allocation.PlaceId,
		Members = Room.Members,
	})

	return true
end

function RoomService.KickMember(Leader: Player, RoomId: string, TargetUserId: number)
	if not Leader or typeof(RoomId) ~= "string" or typeof(TargetUserId) ~= "number" then
		return false
	end

	local Removed = false
	local Valid = false

	pcall(function()
		RoomStore:UpdateAsync(RoomId, function(Room)
			if typeof(Room) ~= "table" then
				return nil
			end

			if not IsRoomAlive(Room) then
				return nil
			end

			if Leader.UserId ~= Room.Leader then
				return Room
			end

			if TargetUserId == Room.Leader then
				return Room
			end

			for i, UserId in ipairs(Room.Members) do
				if UserId == TargetUserId then
					table.remove(Room.Members, i)
					Removed = true
					break
				end
			end

			Valid = true
			return Room
		end, CONFIG.RoomTTL)
	end)

	if not Valid or not Removed then
		return false
	end

	Broadcast(RoomId, {
		Type = "Kick",
		TargetUserId = TargetUserId,
		KickedBy = Leader.UserId,
	})
	return true
end

function RoomService.SetRoomLocked(Leader: Player, RoomId: string, IsLocked: boolean)
	if not Leader or typeof(RoomId) ~= "string" then
		return false
	end

	IsLocked = IsLocked == true

	local Success = false

	pcall(function()
		RoomStore:UpdateAsync(RoomId, function(Room)
			if typeof(Room) ~= "table" then
				return nil
			end

			if not IsRoomAlive(Room) then
				return nil
			end

			if Leader.UserId ~= Room.Leader then
				return Room
			end

			Room.Locked = IsLocked
			Success = true

			return Room
		end, CONFIG.RoomTTL)
	end)

	if Success then
		Broadcast(RoomId, {
			Type = "LockedChanged",
			Locked = IsLocked,
		})
	end

	return Success
end

if not RunService:IsStudio() then
	pcall(function()
		MessagingService:SubscribeAsync(ROOM_TOPIC, function(Message)
			local Data = Message.Data
			if typeof(Data) ~= "table" then
				return
			end

			local RoomId = Data.RoomId
			if typeof(RoomId) ~= "string" then
				return
			end

			if Data.Type == "Kick" then
				local TargetUserId = Data.TargetUserId
				if typeof(TargetUserId) ~= "number" then
					return
				end

				local Player = Players:GetPlayerByUserId(TargetUserId)
				if not Player then
					return
				end

				RoomService.ClearPlayerRoom(TargetUserId)

				Remotes.RoomUpdate:FireClient(Player, {
					Type = "Kicked",
					RoomId = RoomId,
				})

				Matchmaking.CancelQueue(Player)
			elseif Data.Type == "QueueStart" then
				local LocalPlayers = {}

				for _, UserId in ipairs(Data.Members or {}) do
					local P = Players:GetPlayerByUserId(UserId)
					if P then
						table.insert(LocalPlayers, P)
					end
				end

				if #LocalPlayers <= 0 then
					return
				end

				local TeleportData = {
					Mode = Data.Mode,
					Region = Data.Region,
					AccessCode = Data.AccessCode,
					RunId = Data.RunId,
					Capacity = Data.Capacity,
					PartyId = RoomId,
					PartySize = #LocalPlayers,
					Reason = "RoomPublicQueue",
				}

				local Options = Instance.new("TeleportOptions")
				Options.ReservedServerAccessCode = Data.AccessCode
				Options:SetTeleportData(TeleportData)

				TeleportService:TeleportAsync(
					Data.PlaceId,
					LocalPlayers,
					Options
				)
			else
				-- State updates (Joined, Destroyed, LockedChanged, etc.)
				local Room = RoomService.GetRoom(RoomId)
				if not Room then
					return
				end

				for _, UserId in ipairs(Room.Members) do
					local Player = Players:GetPlayerByUserId(UserId)
					if Player then
						-- Hook UI
					end
				end
			end
		end)
	end)
end

return RoomService
