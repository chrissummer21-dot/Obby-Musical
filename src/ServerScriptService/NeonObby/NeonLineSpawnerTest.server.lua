local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

---------------------------------------------------------------------
-- Protección: solo un conductor global
---------------------------------------------------------------------
if _G.NeonConductorStarted then
	warn("[NeonConductor] Ya había un conductor corriendo, este se cancela:", script:GetFullName())
	return
end
_G.NeonConductorStarted = true
print("[NeonConductor] Iniciado en", script:GetFullName())

---------------------------------------------------------------------
-- Referencias
---------------------------------------------------------------------
local music = workspace:WaitForChild("Music")
local templateDown = workspace:WaitForChild("NeonLineTemplateDown")
local templateUp = workspace:WaitForChild("NeonLineTemplateUp")
local endPart = workspace:WaitForChild("NeonLineEnd")

local chartValue = ReplicatedStorage:WaitForChild("NeonChartJson")
local chartData = HttpService:JSONDecode(chartValue.Value)

-- Asegurar que la música NO arranca sola
music:Stop()
music.TimePosition = 0
music.Playing = false

-- 🔒 Bloqueo: nadie puede reproducir la música hasta que nosotros digamos
local allowMusicPlay = false
music:GetPropertyChangedSignal("Playing"):Connect(function()
	if not allowMusicPlay and music.Playing then
		print("[NeonConductor] Bloqueado intento temprano de reproducir música")
		music:Stop()
		music.TimePosition = 0
		music.Playing = false
	end
end)

---------------------------------------------------------------------
-- Notas reales desde el JSON
---------------------------------------------------------------------
local rawNotes = chartData.notes or {}
local notes = {}

for _, n in ipairs(rawNotes) do
	if n.t ~= nil then
		table.insert(notes, { t = n.t })
	end
end

table.sort(notes, function(a, b)
	return (a.t or 0) < (b.t or 0)
end)

if #notes == 0 then
	warn("[NeonConductor] No hay notas en chartData.notes")
	return
end

---------------------------------------------------------------------
-- Sistema de checkpoints
---------------------------------------------------------------------
local lastCheckpoint = {}      -- [player] = BasePart
local allCheckpoints = {}      -- lista de todos los checkpoints
local spawnLocation = workspace:FindFirstChildWhichIsA("SpawnLocation")

local function getSafeCheckpoint(player)
	if lastCheckpoint[player] then
		return lastCheckpoint[player]
	end
	if spawnLocation then
		return spawnLocation
	end
	if #allCheckpoints > 0 then
		return allCheckpoints[1]
	end
	if templateDown then
		return templateDown
	end
	if templateUp then
		return templateUp
	end
	return nil
end

local function sendToLastCheckpoint(player)
	if not player or not player.Character then
		return
	end

	local cp = getSafeCheckpoint(player)
	if not cp then
		warn("[Checkpoint] No se encontró ningún checkpoint / spawn para", player.Name)
		return
	end

	local char = player.Character
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChild("Humanoid")

	if not hrp or not humanoid then
		return
	end

	local cpPos = cp.Position
	local safeY = math.max(cpPos.Y, 5)
	local targetPos = Vector3.new(cpPos.X, safeY + 4, cpPos.Z)

	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	humanoid:ChangeState(Enum.HumanoidStateType.Landed)

	hrp.CFrame = CFrame.new(targetPos, targetPos + hrp.CFrame.LookVector)

	print(string.format(
		"[Checkpoint TP] %s -> %s (%.2f, %.2f, %.2f)",
		player.Name,
		cp.Name,
		targetPos.X, targetPos.Y, targetPos.Z
	))
end

local function registerCheckpoint(part)
	table.insert(allCheckpoints, part)

	part.Touched:Connect(function(hit)
		local char = hit.Parent
		if not char then return end

		local humanoid = char:FindFirstChild("Humanoid")
		if not humanoid then return end

		local player = Players:GetPlayerFromCharacter(char)
		if not player then return end

		lastCheckpoint[player] = part
		print("[Checkpoint] guardado para", player.Name, "->", part.Name, part.Position)
	end)
end

-- Buscar checkpoints en el mapa
local checkpointsFolder = workspace:FindFirstChild("Checkpoints")
if checkpointsFolder then
	for _, inst in ipairs(checkpointsFolder:GetChildren()) do
		if inst:IsA("BasePart") then
			registerCheckpoint(inst)
		end
	end
else
	for _, inst in ipairs(workspace:GetChildren()) do
		if inst:IsA("BasePart") and inst.Name:match("^Checkpoint") then
			registerCheckpoint(inst)
		end
	end
end

---------------------------------------------------------------------
-- Config de viaje, delays y cooldowns
---------------------------------------------------------------------
local LINE_LIFETIME     = 2.0
local MUSIC_DELAY       = LINE_LIFETIME
local UP_COOLDOWN       = 2.0   -- segundos mínimos entre dos líneas Up

local INITIAL_DELAY     = 4.0   -- ⏱️ espera antes de todo
local WORLD_LOAD_DELAY  = 3.0   -- ⏱️ dejar cargar mundo tras HRP

---------------------------------------------------------------------
-- Debounce por jugador para golpes de línea
---------------------------------------------------------------------
local hitDebounce = {} -- [player] = lastHitTime

---------------------------------------------------------------------
-- Spawnear una barra para una nota concreta
---------------------------------------------------------------------
local function spawnNeonLine(noteTime, noteIndex, isUp)
	local sourceTemplate = isUp and templateUp or templateDown

	local line = sourceTemplate:Clone()
	line.Anchored = true
	line.CanCollide = false
	line.CanTouch = true
	line.Massless = true
	line.Parent = workspace
	line.CFrame = sourceTemplate.CFrame

	line.Transparency = 0.1

	line.Touched:Connect(function(hit)
		local char = hit.Parent
		if not char then return end

		local humanoid = char:FindFirstChild("Humanoid")
		if not humanoid then return end

		local player = Players:GetPlayerFromCharacter(char)
		if not player then return end

		local now = tick()
		if hitDebounce[player] and (now - hitDebounce[player]) < 0.25 then
			return
		end
		hitDebounce[player] = now

		sendToLastCheckpoint(player)
	end)

	local tweenInfo = TweenInfo.new(
		LINE_LIFETIME,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.Out
	)

	local startPos = line.Position
	local endZ = endPart.Position.Z
	local targetPos = Vector3.new(startPos.X, startPos.Y, endZ)

	local currentCF = line.CFrame
	local goalCF = CFrame.new(targetPos, targetPos + currentCF.LookVector)

	local goal = { CFrame = goalCF }

	local tween = TweenService:Create(line, tweenInfo, goal)
	tween:Play()

	tween.Completed:Connect(function()
		local songPos = music.TimePosition
		local expectedSongPos = noteTime
		local diff = songPos - expectedSongPos

		print(string.format(
			"[SYNC] Nota #%d -> esperado=%.3f s, canción=%.3f s, diff=%.3f",
			noteIndex,
			expectedSongPos,
			songPos,
			diff
		))

		line:Destroy()
	end)
end

---------------------------------------------------------------------
-- Mover origen y destino con el jugador en Z
---------------------------------------------------------------------
local referencePlayer = nil
local referenceHRP = nil

local initialPlayerZ = nil
local templateDownInitialCFrame = templateDown.CFrame
local templateUpInitialCFrame = templateUp.CFrame
local endInitialCFrame = endPart.CFrame

local function setupReferenceFor(player)
	player.CharacterAdded:Connect(function(char)
		if referencePlayer == nil then
			referencePlayer = player
			referenceHRP = char:WaitForChild("HumanoidRootPart")
			initialPlayerZ = referenceHRP.Position.Z

			templateDownInitialCFrame = templateDown.CFrame
			templateUpInitialCFrame = templateUp.CFrame
			endInitialCFrame = endPart.CFrame

			print("[NeonConductor] Reference player listo:", player.Name)
		end
	end)

	if player.Character and referencePlayer == nil then
		referencePlayer = player
		referenceHRP = player.Character:WaitForChild("HumanoidRootPart")
		initialPlayerZ = referenceHRP.Position.Z

		templateDownInitialCFrame = templateDown.CFrame
		templateUpInitialCFrame = templateUp.CFrame
		endInitialCFrame = endPart.CFrame

		print("[NeonConductor] Reference player listo (Character ya existía):", player.Name)
	end
end

for _, plr in ipairs(Players:GetPlayers()) do
	setupReferenceFor(plr)
end

Players.PlayerAdded:Connect(setupReferenceFor)

local function setCFrameWithNewZ(baseCFrame, newZ)
	local pos = baseCFrame.Position
	local look = baseCFrame.LookVector
	local newPos = Vector3.new(pos.X, pos.Y, newZ)
	return CFrame.new(newPos, newPos + look)
end

---------------------------------------------------------------------
-- Conductor: delays + reloj interno + música + spawn de líneas
---------------------------------------------------------------------
local songClock = 0
local currentIndex = 1
local musicStarted = false

local lastUpTime = -1e9

local initialReady = false
local initialTimer = 0

local worldReady = false
local worldLoadTimer = 0

RunService.Heartbeat:Connect(function(dt)
	-- 0) Espera inicial
	if not initialReady then
		initialTimer += dt
		if initialTimer >= INITIAL_DELAY then
			initialReady = true
			print(string.format(
				"[NeonConductor] Delay inicial de %.2f s completado, esperando HRP / mundo...",
				INITIAL_DELAY
			))
		end
		return
	end

	-- 1) Esperar HRP + carga de mundo
	if not worldReady then
		if referenceHRP then
			worldLoadTimer += dt
			if worldLoadTimer >= WORLD_LOAD_DELAY then
				worldReady = true
				print(string.format(
					"[NeonConductor] Mundo listo tras %.2f s, iniciando reloj musical",
					WORLD_LOAD_DELAY
				))
			end
		end
		return
	end

	-- 2) Lógica normal
	songClock += dt

	if referenceHRP and initialPlayerZ then
		local deltaZ = referenceHRP.Position.Z - initialPlayerZ

		local newDownZ = templateDownInitialCFrame.Position.Z + deltaZ
		local newUpZ = templateUpInitialCFrame.Position.Z + deltaZ
		local newEndZ = endInitialCFrame.Position.Z + deltaZ

		templateDown.CFrame = setCFrameWithNewZ(templateDownInitialCFrame, newDownZ)
		templateUp.CFrame   = setCFrameWithNewZ(templateUpInitialCFrame, newUpZ)
		endPart.CFrame      = setCFrameWithNewZ(endInitialCFrame, newEndZ)
	end

	if not musicStarted and songClock >= MUSIC_DELAY then
		musicStarted = true

		-- 🔁 Al iniciar la canción, mandar a todos al spawn/checkpoint
		for _, player in ipairs(Players:GetPlayers()) do
			sendToLastCheckpoint(player)
		end

		music.TimePosition = 0
		allowMusicPlay = true   -- ahora sí dejamos que suene
		music:Play()

		print(string.format("[SYNC] Música iniciada en t=%.3f (songClock)", songClock))
	end

	while currentIndex <= #notes do
		local noteTime = notes[currentIndex].t or 0

		if songClock >= noteTime then
			local isUpAllowed = (songClock - lastUpTime) >= UP_COOLDOWN
			local isUp

			if isUpAllowed then
				isUp = (math.random() < 0.5)
			else
				isUp = false
			end

			if isUp then
				lastUpTime = songClock
			end

			spawnNeonLine(noteTime, currentIndex, isUp)
			currentIndex += 1
		else
			break
		end
	end
end)

---------------------------------------------------------------------
-- Void check
---------------------------------------------------------------------
local VOID_Y = -20

RunService.Heartbeat:Connect(function()
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char then
			local hrp = char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp.Position.Y < VOID_Y then
				sendToLastCheckpoint(player)
			end
		end
	end
end)
