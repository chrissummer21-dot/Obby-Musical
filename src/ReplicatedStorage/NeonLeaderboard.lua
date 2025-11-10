-- ReplicatedStorage.NeonLeaderboard

local DataStoreService = game:GetService("DataStoreService")

local bestStore      = DataStoreService:GetDataStore("NeonBestScore_v2")
local orderedStore   = DataStoreService:GetOrderedDataStore("NeonBestScoreOrdered_v2")

local Leaderboard = {}

-- Comprime percent + time en un número para OrderedDataStore
-- Queremos: más % = mejor, a mismo % menor tiempo = mejor
local function makeScoreKey(percent, timeSec)
	percent = tonumber(percent) or 0
	timeSec = tonumber(timeSec) or 0

	-- guardamos percent * 100 (dos decimales) y time * 100
	local p = math.floor(percent * 100 + 0.5)
	local t = math.floor(timeSec * 100 + 0.5)

	-- invertimos el tiempo para que menor tiempo sea mayor score
	local invTime = 999999 - math.clamp(t, 0, 999999)

	-- score grande: primero % (peso fuerte), luego tiempo invertido
	return p * 1_000_000 + invTime
end

---------------------------------------------------------------------
-- Guarda / actualiza mejor run de ese jugador
---------------------------------------------------------------------
function Leaderboard.RegisterRunEnd(player, data)
	local userId = player.UserId
	local userKey = "u_" .. userId

	local percent = tonumber(data.percent) or 0
	local timeSec = tonumber(data.timeSec) or 0

	local newRecord = {
		UserId      = userId,
		Username    = player.Name,
		BestPercent = percent,
		BestTimeSec = timeSec,
		UpdatedAt   = os.time(),
	}

	-- DataStore normal: guarda tabla ✅ (no double suelto)
	local finalRecord
	local ok, err = pcall(function()
		finalRecord = bestStore:UpdateAsync(userKey, function(old)
			if not old then
				return newRecord
			end

			local oldP = tonumber(old.BestPercent) or 0
			local oldT = tonumber(old.BestTimeSec) or 1e9

			if percent > oldP then
				return newRecord
			elseif percent == oldP and timeSec < oldT then
				return newRecord
			else
				return old
			end
		end)
	end)

	if not ok then
		warn("[NeonLeaderboard] UpdateAsync error:", err)
		finalRecord = newRecord
	end

	-- OrderedDataStore: solo número
	local scoreKey = makeScoreKey(percent, timeSec)
	pcall(function()
		orderedStore:SetAsync(userKey, scoreKey)
	end)

	return finalRecord
end

---------------------------------------------------------------------
-- Devuelve top N global
--  {
--    { Rank = 1, UserId = ..., Username = "...", BestPercent = 100, BestTimeSec = 55.33 },
--    ...
--  }
---------------------------------------------------------------------
function Leaderboard.GetTop(n)
	n = n or 10

	local ok, pages = pcall(function()
		-- false = orden descendente (mayor score primero)
		return orderedStore:GetSortedAsync(false, n)
	end)

	if not ok then
		warn("[NeonLeaderboard] GetTop error:", pages)
		return {}
	end

	local data = pages:GetCurrentPage()
	local result = {}
	local rank = 0

	for _, entry in ipairs(data) do
		rank += 1
		local userKey = entry.key         -- "u_123456"
		local userId = tonumber(userKey:match("%d+")) or 0

		local stored
		local ok2, res = pcall(function()
			return bestStore:GetAsync(userKey)
		end)
		if ok2 and res then
			stored = res
		else
			stored = {
				UserId      = userId,
				Username    = "User" .. userId,
				BestPercent = 0,
				BestTimeSec = 0,
			}
		end

		table.insert(result, {
			Rank        = rank,
			UserId      = stored.UserId or userId,
			Username    = stored.Username or ("User" .. userId),
			BestPercent = stored.BestPercent or 0,
			BestTimeSec = stored.BestTimeSec or 0,
		})
	end

	return result
end

return Leaderboard
