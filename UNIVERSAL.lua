local VBL_PLACES = {
    [73956553001240] = true,
    [74691681039273] = true,
}

local RIVALS_PLACE = 17625359962

local placeId = game.PlaceId

if VBL_PLACES[placeId] then

    print("[LOCOPANI UNIVERSAL] Volleyball Legends detectado")

    local VBL_URL = "https://raw.githubusercontent.com/locopanison-crypto/universal/refs/heads/main/LOCOPANI_VBL.lua"

local source = game:HttpGet(VBL_URL)
local script = loadstring(source)

if script then
    script()
else
    warn("[LOCOPANI UNIVERSAL] Não foi possível carregar o LOCOPANI VBL")
end

elseif placeId == RIVALS_PLACE then

    print("[LOCOPANI UNIVERSAL] RIVALS detectado")

    -- carregar RIVALS.lua

else

    warn("[LOCOPANI UNIVERSAL] Jogo não suportado: " .. tostring(placeId))

end
