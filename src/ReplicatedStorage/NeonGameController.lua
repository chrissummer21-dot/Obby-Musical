local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Game = {}
Game._inited = false

-- Leaderboard global
local Leaderboard = require(ReplicatedStorage:WaitForChild("NeonLeaderboard"))

local MAX_LIVES = 3
local lives = {}              -- [player] = vidas restantes
local finished = {}           -- [player] = true si tocó Puntofinal
local recordedScore = {}      -- [player] = true si ya se guardó su run
local autoRestartScheduled = false

-- RemoteEvent para mostrar la tabla al morir
local resultsEvent = ReplicatedStorage:FindFirstChild("NeonShowResults")
if not resultsEvent then
	resultsEvent = Instance.new("RemoteEvent")
	resultsEvent.Name = "NeonShowResults"
	resultsEvent.Parent = ReplicatedStorage
end

---------------------------------------------------------------------
-- Señales globales
---------------------------------------------------------------------
local signalsFolder = ReplicatedStorage:FindFirstChild("NeonGameSignals")
if not signalsFolder then
	signalsFolder = Instance.new("Folder")
	signalsFolder.Name = "NeonGameSignals"
	signalsFolder.Parent = ReplicatedStorage
end

local onRoundRestart = signalsFolder:FindFirstChild("OnRoundRestart")
if not onRoundRestart then
	onRoundRestart = Instance.new("BindableEvent")
	onRoundRestart.Name = "OnRoundRestart"
	onRoundRestart.Parent = signalsFolder
end

local onRoundStart = signalsFolder:FindFirstChild("OnRoundStart")
if not onRoundStart then
	onRoundStart = Instance.new("BindableEvent")
	onRoundStart.Name = "OnRoundStart"
	onRoundStart.Parent = signalsFolder
end

local onRoundStop = signalsFolder:FindFirstChild("OnRoundStop")
if not onRoundStop then
	onRoundStop = Instance.new("BindableEvent")
	onRoundStop.Name = "OnRoundStop"
	onRoundStop.Parent = signalsFolder
end

---------------------------------------------------------------------
-- Referencias globales
---------------------------------------------------------------------
local music : Sound
local templateDown : BasePart
local templateUp : BasePart
local endPart : BasePart

local chartData
local notes = {}

-- checkpoints
local lastCheckpoint = {}
local allCheckpoints = {}
local spawnLocation : BasePart?
local startCheckpoint : BasePart? -- Checkpoint1

-- referencia de jugador
local referencePlayer : Player?
local referenceHRP : BasePart?
local initialPlayerZ : number?

local templateDownInitialCFrame : CFrame
local templateUpInitialCFrame : CFrame
local endInitialCFrame : CFrame

-- configuración
local LINE_LIFETIME     = 2.0
local MUSIC_DELAY       = LINE_LIFETIME
local UP_COOLDOWN       = 2.0

local INITIAL_DELAY     = 4.0
local WORLD_LOAD_DELAY  = 3.0

-- estado runtime
local running         = false
local songClock       = 0
local currentIndex    = 1
local musicStarted    = false
local lastUpTime      = -1e9

local initialReady    = false
local initialTimer    = 0

local worldReady      = false
local worldLoadTimer  = 0

local allowMusicPlay  = false
local hitDebounce     = {}      -- [player] = lastHitTime
local activeLines     = {}      -- para limpiar al reiniciar

local VOID_Y = -20

-- track Z (para porcentaje cuando NO ha terminado)
Game._trackStartZ = nil
Game._trackEndZ   = nil

---------------------------------------------------------------------
-- Utils
---------------------------------------------------------------------
local function resetRuntimeState()
	running         = false
	songClock       = 0
	currentIndex    = 1
	musicStarted    = false
	lastUpTime      = -1e9

	initialReady    = false
	initialTimer    = 0

	worldLoadTimer  = 0
	allowMusicPlay  = false
	hitDebounce     = {}
	autoRestartScheduled = false

	-- limpiamos referencias de último checkpoint
	lastCheckpoint = {}

	-- limpiar líneas activas
	for _, line in ipairs(activeLines) do
		if line and line.Parent then
			line:Destroy()
		end
	end
	table.clear(activeLines)

	-- limpiar flags de fin / score
	for plr in pairs(finished) do
		finished[plr] = nil
	end
	for plr in pairs(recordedScore) do
		recordedScore[plr] = nil
	end

	-- reset música
	if music then
		music:Stop()
		music.TimePosition = 0
		music.Playing = false
	end
end

local function getSafeCheckpoint(player : Player)
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

local function sendToLastCheckpoint(player : Player)
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

local function registerCheckpoint(part : BasePart)
	table.insert(allCheckpoints, part)

	if part.Name == "Checkpoint1" then
		startCheckpoint = part
		print("[NeonGameController] StartCheckpoint = Checkpoint1")
	end

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

local function setCFrameWithNewZ(baseCFrame : CFrame, newZ : number)
	local pos = baseCFrame.Position
	local look = baseCFrame.LookVector
	local newPos = Vector3.new(pos.X, pos.Y, newZ)
	return CFrame.new(newPos, newPos + look)
end

---------------------------------------------------------------------
-- % completado basado en Z entre Checkpoint1 y Puntofinal
-- (solo se usa si NO ha tocado Puntofinal)
---------------------------------------------------------------------
local function computePercentForPlayer(player : Player)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not Game._trackStartZ or not Game._trackEndZ then
		return 0
	end

	local z = hrp.Position.Z
	local a = Game._trackStartZ
	local b = Game._trackEndZ
	local total = math.abs(b - a)
	if total <= 0 then return 0 end

	local sign = (b >= a) and 1 or -1
	local traveled = (z - a) * sign
	traveled = math.clamp(traveled, 0, total)

	return (traveled / total) * 100
end

---------------------------------------------------------------------
-- GAME OVER de un jugador (vidas agotadas o Puntofinal)
---------------------------------------------------------------------
function Game.GameOverPlayer(player : Player)
	if not player then return end

	-- evitar múltiples escrituras por ronda
	if recordedScore[player] then
		return
	end
	recordedScore[player] = true

	-- decidir porcentaje
	local percent
	if finished[player] then
		percent = 100
	else
		percent = computePercentForPlayer(player)
	end

	-- sanitizar números para DataStore
	if percent ~= percent then percent = 0 end
	percent = math.clamp(percent, 0, 100)

	-- tiempo desde que empezó la música
	local timeSec = math.max(0, songClock - MUSIC_DELAY)
	if timeSec ~= timeSec then timeSec = 0 end

	-- registrar en datastore
	local statsFromStore = Leaderboard.RegisterRunEnd(player, {
		percent = percent,
		timeSec = timeSec,
	})

	-- obtener top bruto
	local rawTop = Leaderboard.GetTop(10) or {}
	local topForClient = {}
	local rank = nil

	for _, row in ipairs(rawTop) do
		local username = row.Username or row.Name or ("User" .. tostring(row.UserId or "?"))
		local bestPercent = row.BestPercent or row.Percent or 0
		local bestTime = row.BestTime or row.BestTimeSec or row.TimeSec or 0

		table.insert(topForClient, {
			username = username,
			percent = bestPercent,
			time = bestTime,
		})

		if row.UserId == player.UserId then
			rank = row.Rank or rank
		end
	end

	local myStatsForClient = {
		username = player.Name,
		percent = percent,
		time = timeSec,
		rank = rank,
	}

	if resultsEvent then
		resultsEvent:FireClient(player, myStatsForClient, topForClient)
	end

	print("[NeonGameController] GAME OVER para", player.Name, "percent=", percent, "time=", timeSec)

	-- auto-restart global después de unos segundos
	if not autoRestartScheduled then
		autoRestartScheduled = true
		task.delay(6, function()
			autoRestartScheduled = false
			Game.RestartRound()
		end)
	end
end

---------------------------------------------------------------------
-- Manejo de fallos (línea / vacío)
---------------------------------------------------------------------
local function handlePlayerFail(player : Player)
	if not player then return end

	if lives[player] ~= nil and lives[player] <= 0 then
		return
	end

	if lives[player] == nil then
		lives[player] = MAX_LIVES
	end

	lives[player] = lives[player] - 1
	print("[NeonGameController] Player", player.Name, "perdió una vida. Quedan:", lives[player])

	if lives[player] > 0 then
		sendToLastCheckpoint(player)
	else
		Game.GameOverPlayer(player)
	end
end

---------------------------------------------------------------------
-- Líneas
---------------------------------------------------------------------
local function spawnNeonLine(noteTime : number, noteIndex : number, isUp : boolean)
	local sourceTemplate = isUp and templateUp or templateDown
	if not sourceTemplate then return end

	local line = sourceTemplate:Clone()
	line.Name = "NeonLineRuntime"
	line.Anchored = true
	line.CanCollide = false
	line.CanTouch = true
	line.Massless = true
	line.Parent = workspace
	line.CFrame = sourceTemplate.CFrame
	line.Transparency = 0.1

	table.insert(activeLines, line)

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

		handlePlayerFail(player)
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
		if music then
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
		end
		line:Destroy()
	end)
end

---------------------------------------------------------------------
-- Referencia de jugador
---------------------------------------------------------------------
local function setupReferenceFor(player : Player)
	player.CharacterAdded:Connect(function(char)
		if referencePlayer == nil then
			referencePlayer = player
			referenceHRP = char:WaitForChild("HumanoidRootPart")
			initialPlayerZ = referenceHRP.Position.Z

			templateDownInitialCFrame = templateDown.CFrame
			templateUpInitialCFrame   = templateUp.CFrame
			endInitialCFrame          = endPart.CFrame

			print("[NeonGameController] Reference player listo:", player.Name)
		end
	end)

	if player.Character and referencePlayer == nil then
		referencePlayer = player
		referenceHRP = player.Character:WaitForChild("HumanoidRootPart")
		initialPlayerZ = referenceHRP.Position.Z

		templateDownInitialCFrame = templateDown.CFrame
		templateUpInitialCFrame   = templateUp.CFrame
		endInitialCFrame          = endPart.CFrame

		print("[NeonGameController] Reference player listo (Character ya existía):", player.Name)
	end
end

---------------------------------------------------------------------
-- Heartbeat principal
---------------------------------------------------------------------
local function onHeartbeat(dt : number)
	-- Void check SIEMPRE
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char then
			local hrp = char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp.Position.Y < VOID_Y then
				handlePlayerFail(player)
			end
		end
	end

	if not running then
		return
	end

	-- 0) Delay inicial
	if not initialReady then
		initialTimer += dt
		if initialTimer >= INITIAL_DELAY then
			initialReady = true
			print(string.format(
				"[NeonGameController] Delay inicial de %.2f s completado, esperando HRP / mundo...",
				INITIAL_DELAY
			))
		end
		return
	end

	-- 1) Esperar HRP + carga de mundo la PRIMER vez
	if not worldReady then
		if referenceHRP then
			worldLoadTimer += dt
			if worldLoadTimer >= WORLD_LOAD_DELAY then
				worldReady = true
				print(string.format(
					"[NeonGameController] Mundo listo tras %.2f s, iniciando reloj musical",
					WORLD_LOAD_DELAY
				))
			end
		end
		return
	end

	-- 2) Lógica normal
	songClock += dt

	-- Mover templates con el jugador
	if referenceHRP and initialPlayerZ then
		local deltaZ = referenceHRP.Position.Z - initialPlayerZ

		local newDownZ = templateDownInitialCFrame.Position.Z + deltaZ
		local newUpZ   = templateUpInitialCFrame.Position.Z + deltaZ
		local newEndZ  = endInitialCFrame.Position.Z + deltaZ

		templateDown.CFrame = setCFrameWithNewZ(templateDownInitialCFrame, newDownZ)
		templateUp.CFrame   = setCFrameWithNewZ(templateUpInitialCFrame, newUpZ)
		endPart.CFrame      = setCFrameWithNewZ(endInitialCFrame, newEndZ)
	end

	-- Iniciar música
	if not musicStarted and songClock >= MUSIC_DELAY then
		musicStarted = true

		-- al arrancar la música, mandar todos al Checkpoint1/spawn
		for _, player in ipairs(Players:GetPlayers()) do
			local cp = startCheckpoint or spawnLocation
			if cp then
				lastCheckpoint[player] = cp
				sendToLastCheckpoint(player)
			end
		end

		if music then
			music.TimePosition = 0
			allowMusicPlay = true
			music:Play()
		end

		print(string.format("[SYNC] Música iniciada en t=%.3f (songClock)", songClock))
	end

	-- Spawn de líneas por notas
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
end

---------------------------------------------------------------------
-- API PÚBLICA
---------------------------------------------------------------------
function Game.Init()
	if Game._inited then return end
	Game._inited = true

	-- Referencias
	music        = workspace:WaitForChild("Music")
	templateDown = workspace:WaitForChild("NeonLineTemplateDown")
	templateUp   = workspace:WaitForChild("NeonLineTemplateUp")
	endPart      = workspace:WaitForChild("NeonLineEnd")

	local chartValue = ReplicatedStorage:WaitForChild("NeonChartJson")
	chartData = HttpService:JSONDecode(chartValue.Value)

	-- track Z y final real
	local checkpointsFolder = workspace:WaitForChild("Checkpoints")
	local trackStart = checkpointsFolder:WaitForChild("Checkpoint1")
	local trackEnd   = workspace:WaitForChild("Puntofinal")

	Game._trackStartZ = trackStart.Position.Z
	Game._trackEndZ   = trackEnd.Position.Z

	-- marcar fin al tocar Puntofinal (100%)
	trackEnd.Touched:Connect(function(hit)
		local char = hit.Parent
		if not char then return end

		local humanoid = char:FindFirstChild("Humanoid")
		if not humanoid then return end

		local player = Players:GetPlayerFromCharacter(char)
		if not player then return end

		finished[player] = true
		print("[NeonGameController] Player terminó pista:", player.Name)

		Game.GameOverPlayer(player)
	end)

	-- Música bloqueada al inicio
	music:Stop()
	music.TimePosition = 0
	music.Playing = false
	allowMusicPlay = false

	music:GetPropertyChangedSignal("Playing"):Connect(function()
		if not allowMusicPlay and music.Playing then
			print("[NeonGameController] Bloqueado intento temprano de reproducir música")
			music:Stop()
			music.TimePosition = 0
			music.Playing = false
		end
	end)

	-- Notas
	local rawNotes = chartData.notes or {}
	notes = {}
	for _, n in ipairs(rawNotes) do
		if n.t ~= nil then
			table.insert(notes, { t = n.t })
		end
	end
	table.sort(notes, function(a, b)
		return (a.t or 0) < (b.t or 0)
	end)

	if #notes == 0 then
		warn("[NeonGameController] No hay notas en chartData.notes")
	end

	-- Checkpoints
	lastCheckpoint = {}
	allCheckpoints = {}
	spawnLocation = workspace:FindFirstChildWhichIsA("SpawnLocation")

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

	-- Referencia de jugador
	for _, plr in ipairs(Players:GetPlayers()) do
		setupReferenceFor(plr)
	end
	Players.PlayerAdded:Connect(setupReferenceFor)

	-- vidas iniciales
	for _, plr in ipairs(Players:GetPlayers()) do
		lives[plr] = MAX_LIVES
	end

	Players.PlayerAdded:Connect(function(plr)
		lives[plr] = MAX_LIVES
	end)

	Players.PlayerRemoving:Connect(function(plr)
		lives[plr] = nil
		finished[plr] = nil
		recordedScore[plr] = nil
	end)

	-- Heartbeat global
	RunService.Heartbeat:Connect(onHeartbeat)

	print("[NeonGameController] Init completo")
end

function Game.StartRound()
	resetRuntimeState()
	running = true

	-- resetear vidas de todos
	for _, plr in ipairs(Players:GetPlayers()) do
		lives[plr] = MAX_LIVES
	end

	onRoundStart:Fire()
	print("[NeonGameController] StartRound")
end

function Game.StopRound()
	running = false
	if music then
		music:Stop()
		music.Playing = false
	end
	onRoundStop:Fire()
	print("[NeonGameController] StopRound")
end

function Game.RestartRound()
	print("[NeonGameController] RestartRound")

	Game.StopRound()
	Game.StartRound()

	-- Mandar a todos a Checkpoint1 (o spawn si no existe)
	for _, player in ipairs(Players:GetPlayers()) do
		local cp = startCheckpoint or spawnLocation
		if cp then
			lastCheckpoint[player] = cp
			sendToLastCheckpoint(player)
		end
	end

	onRoundRestart:Fire()
end

return Game
