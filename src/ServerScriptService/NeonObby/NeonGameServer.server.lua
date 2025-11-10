local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameController = require(ReplicatedStorage:WaitForChild("NeonGameController"))

-- RemoteEvent para recibir órdenes desde el cliente (restart botón)
local evt = ReplicatedStorage:FindFirstChild("GameControlEvent")
if not evt then
	evt = Instance.new("RemoteEvent")
	evt.Name = "GameControlEvent"
	evt.Parent = ReplicatedStorage
end

GameController.Init()
GameController.StartRound()

evt.OnServerEvent:Connect(function(player, action)
	if action == "restart" then
		print("[NeonGameServer] Restart pedido por", player.Name)
		GameController.RestartRound()
	elseif action == "stop" then
		GameController.StopRound()
	elseif action == "start" then
		GameController.StartRound()
	end
end)
