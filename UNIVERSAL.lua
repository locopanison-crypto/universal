local VBL_PLACES = {
    [73956553001240] = true,
    [74691681039273] = true,
}

local RIVALS_PLACE = 17625359962
local placeId = game.PlaceId

if VBL_PLACES[placeId] then

    print("[LOCOPANI UNIVERSAL] Volleyball Legends detectado!")

    -- Mantenha aqui o carregamento VBL que já funciona

elseif placeId == RIVALS_PLACE then

    print("[LOCOPANI UNIVERSAL] RIVALS detectado!")

    local function StartRivalsModule()

        local RIVALS_URL = "https://raw.githubusercontent.com/locopanison-crypto/universal/refs/heads/main/RIVALS.lua"

        print("[LOCOPANI] Endereço do módulo: " .. RIVALS_URL)

        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "LOCOPANI UNIVERSAL",
                Text = "RIVALS detectado!",
                Duration = 5
            })
        end)
    end

    StartRivalsModule()

else

    warn("[LOCOPANI UNIVERSAL] Jogo não suportado: " .. tostring(placeId))

end
