local VBL_PLACES = {
    [73956553001240] = true,
    [74691681039273] = true,
}

local RIVALS_PLACE = 17625359962
local placeId = game.PlaceId

if VBL_PLACES[placeId] then

    print("[LOCOPANI UNIVERSAL] Volleyball Legends detectado!")

    local VBL_URL = "https://raw.githubusercontent.com/locopanison-crypto/universal/refs/heads/main/LOCOPANI_VBL.lua"

local ok, err = pcall(function()
    local source = game:HttpGet(VBL_URL)
    local scriptFunction = assert(loadstring(source))
    scriptFunction()
end)

if not ok then
    warn("[LOCOPANI UNIVERSAL] Erro ao iniciar RIVALS: " .. tostring(err))
end

elseif placeId == RIVALS_PLACE then

    print("[LOCOPANI UNIVERSAL] RIVALS detectado!")

   local RIVALS_URL = "https://raw.githubusercontent.com/locopanison-crypto/universal/refs/heads/main/RIVALS.lua"

local ok, err = pcall(function()
    local source = game:HttpGet(VBL_URL)
    local scriptFunction = assert(loadstring(source))
    scriptFunction()
end)

if not ok then
    warn("[LOCOPANI UNIVERSAL] Erro ao iniciar VBL: " .. tostring(err))
end

    warn("[LOCOPANI UNIVERSAL] Jogo não suportado: " .. tostring(placeId))

end
