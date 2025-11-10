local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

-- 👇 DataStore donde ya estás guardando los mejores datos
local bestStore = DataStoreService:GetDataStore("NeonBestScore_v2")

local function setupLeaderstats(player: Player)
	-- Carpeta que Roblox usa para la barra "Personas"
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	ls.Parent = player

	local percent = Instance.new("IntValue")
	percent.Name = "Percent"          -- progreso actual (lo que verá la barra)
	percent.Value = 0
	percent.Parent = ls

	local timeVal = Instance.new("NumberValue")
	timeVal.Name = "Time"             -- tiempo de la mejor run (o la que guardes)
	timeVal.Value = 0
	timeVal.Parent = ls

	local completed = Instance.new("IntValue")
	completed.Name = "Completed"      -- 0 / 1 si completó
	completed.Value = 0
	completed.Parent = ls

	local bestPercent = Instance.new("IntValue")
	bestPercent.Name = "BestPercent"  -- mejor % histórico
	bestPercent.Value = 0
	bestPercent.Parent = ls

	-- 🔁 Cargar desde NeonBestScore_v2
	task.spawn(function()
		local key = "u_" .. player.UserId

		local ok, data = pcall(function()
			return bestStore:GetAsync(key)
		end)

		if not ok then
			warn("[NeonPlayerListBridge] Error GetAsync para", player.Name, data)
			return
		end
		if not data then
			return -- sin datos guardados todavía
		end

		-- Intenta mapear campos típicos del DataStore v2
		-- ajusta los nombres si tu tabla tiene otros
		local storedPercent   = tonumber(data.percent or data.bestPercent or 0) or 0
		local storedTime      = tonumber(data.timeSec or data.time or 0) or 0
		local storedCompleted = data.completed or data.isCompleted or false
		local storedBest      = tonumber(data.bestPercent or storedPercent) or 0

		percent.Value     = math.floor(storedPercent + 0.5)
		timeVal.Value     = storedTime
		completed.Value   = storedCompleted and 1 or 0
		bestPercent.Value = math.floor(storedBest + 0.5)
	end)
end

-- Conectar a todos los jugadores
Players.PlayerAdded:Connect(setupLeaderstats)
for _, plr in ipairs(Players:GetPlayers()) do
	setupLeaderstats(plr)
end
