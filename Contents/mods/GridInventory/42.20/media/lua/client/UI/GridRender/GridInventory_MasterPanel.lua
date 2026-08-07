local MasterPanel = ISPanel:derive("GridInventory_MasterPanel")

function MasterPanel:new(x, y, width, height, playerNum)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.backgroundColor = {r=0, g=0, b=0, a=0.8}
    o.borderColor = {r=1, g=1, b=1, a=0.1}
    return o
end

function MasterPanel:initialise()
    ISPanel.initialise(self)
end

function MasterPanel:render()
    ISPanel.render(self)
    -- Pode desenhar bg ou algo customizado aqui
end

return MasterPanel
