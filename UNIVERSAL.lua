-- LOCOPANI UNIVERSAL
-- Sistema de detecção e carregamento automático

local BASE_URL = "https://raw.githubusercontent.com/locopanison-crypto/universal/refs/heads/main/"

local VBL_PLACES = {
    [73956553001240] = true,
    [74691681039273] = true,
}

local RIVALS_PLACE = 17625359962
local placeId = game.PlaceId

local function carregarModulo(nome, arquivo)
    print("[LOCOPANI UNIVERSAL] Iniciando " .. nome .. "...")

    local url = BASE_URL .. arquivo

    local ok, err = pcall(function()
        local source = game:HttpGet(url)
        local executar = assert(loadstring(source))
        executar()
    end)

    if ok then
        print("[LOCOPANI UNIVERSAL] " .. nome .. " carregado!")
    else
        warn("[LOCOPANI UNIVERSAL] Erro em " .. nome .. ": " .. tostring(err))
    end
end

if VBL_PLACES[placeId] then

    print("[LOCOPANI UNIVERSAL] Volleyball Legends detectado!")
    carregarModulo("Volleyball Legends", "LOCOPANI_VBL.lua")

elseif placeId == RIVALS_PLACE then

    print("[LOCOPANI UNIVERSAL] RIVALS detectado!")
    carregarModulo("RIVALS", "RIVALS.lua")

else

    warn("[LOCOPANI UNIVERSAL] Jogo não suportado: " .. tostring(placeId))

end
