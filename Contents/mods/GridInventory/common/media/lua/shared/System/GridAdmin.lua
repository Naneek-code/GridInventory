--- GridAdmin.lua
--- Detecção de ADMIN (B42) compartilhada entre cliente e servidor.
--- Usado pra liberar o DevTool (editar footprint/grid) só pra admins no MP.
---
--- Regras:
---   * SP (host, isClient()=false): o dono do save é admin.
---   * MP (cliente): role com admin power (role:hasAdminPower(), o método NATIVO
---     do B42 — não existe Capability.Admin no enum), nome de role contendo
---     "admin", ou getAccessLevel()=="admin". Fail-closed: sem confirmação → não admin.

local GridAdmin = {}

--- O jogador tem poder de admin?
---@param player IsoPlayer|nil
---@return boolean
function GridAdmin.isAdmin(player)
    if not player then return false end

    -- MP: role/capability (B42) e accessLevel têm precedência — avaliamos
    -- SEMPRE que disponíveis (cobre servidor dedicado e cliente).
    local hasRoleInfo = false
    if player.getRole then
        local role = player:getRole()
        if role then
            hasRoleInfo = true
            -- B42 nativo: role:hasAdminPower() verifica um conjunto de
            -- capabilities de admin (AddItem, SandboxOptions, RolesRead, ...).
            -- É o mesmo método que o vanilla usa no Admin Panel
            -- (ISAdminPanelUI.lua: getPlayer():getRole():hasAdminPower()).
            -- NÃO existe Capability.Admin no enum do B42 — check antigo falhava
            -- silenciosamente e admin do MP nunca era detectado no cliente.
            if role.hasAdminPower then
                if role:hasAdminPower() then return true end
            end
            if role.getName then
                local n = tostring(role:getName() or ""):lower()
                if string.find(n, "admin") then return true end
            end
        end
    end

    if player.getAccessLevel then
        local al = player:getAccessLevel()
        if al then
            hasRoleInfo = true
            if tostring(al):lower() == "admin" then return true end
        end
    end

    -- SP / host local: dono do save = admin (não é cliente conectado). Só
    -- assume admin quando NÃO há info de role/accessLevel (em SP o jogador
    -- geralmente não tem role, então o dono é admin). Se tem role info e
    -- não é admin, NÃO é admin (fail-closed).
    if not (isClient and isClient()) and not hasRoleInfo then
        return true
    end

    return false
end

return GridAdmin
