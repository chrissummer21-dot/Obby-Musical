local Players = game:GetService("Players")

local DISCLAIMER_TIME = 4   -- segundos mostrando el aviso de luces
local READY_TIME      = 3   -- segundos mostrando "ARE YOU READY?"

local player = Players.LocalPlayer

-- Crear la GUI por código
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "IntroMessages"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.BackgroundTransparency = 0.3
label.BackgroundColor3 = Color3.new(0, 0, 0)
label.Size = UDim2.new(1, 0, 1, 0)
label.Position = UDim2.new(0, 0, 0, 0)
label.TextColor3 = Color3.new(1, 1, 1)
label.TextScaled = true
label.Font = Enum.Font.GothamBold
label.Parent = screenGui

-- 1) Disclaimer
label.Text = "WARNING (Atención)\nEste juego contiene luces parpadeantes\nY luces brillantes."
wait(DISCLAIMER_TIME)

-- 2) Are you ready?
label.Text = "ARE YOU READY?"
wait(READY_TIME)

-- 3) Desaparece suave
for i = 1, 20 do
	label.TextTransparency = i / 20
	label.BackgroundTransparency = 0.3 + (i/20)*0.7
	wait(0.05)
end

screenGui:Destroy()
