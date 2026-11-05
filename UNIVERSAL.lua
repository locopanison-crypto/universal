-- ============================================================
-- LOCOPANI UNIVERSAL
-- ============================================================

local VBL_PLACES = {
    [73956553001240] = true,
    [74691681039273] = true,
}

local RIVALS_PLACE = 17625359962

local placeId = game.PlaceId

if VBL_PLACES[placeId] then

    print("[LOCOPANI UNIVERSAL] Volleyball Legends detectado")

    -- LOCOPANI_VBL.lua será carregado separadamente

elseif placeId == RIVALS_PLACE then

    print("[LOCOPANI UNIVERSAL] RIVALS detectado")

    -- RIVALS.lua será carregado separadamente

else

    warn(
        "[LOCOPANI UNIVERSAL] Jogo não suportado. PlaceId: "
        .. tostring(placeId)
    )

end
