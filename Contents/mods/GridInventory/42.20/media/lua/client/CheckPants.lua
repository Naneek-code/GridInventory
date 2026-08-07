local function checkPants()
    local item = ScriptManager.instance:getItem("Base.Trousers")
    if item then
        print("TROUSERS BODY LOC: " .. tostring(item:getBodyLocation()))
    end
end
Events.OnGameBoot.Add(checkPants)
