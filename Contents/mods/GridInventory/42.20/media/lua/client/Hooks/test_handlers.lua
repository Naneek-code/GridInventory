require "ISUI/InventoryWindow/ISInventoryWindowContainerControls"
require "ISUI/LootWindow/ISLootWindowContainerControls"

print("--- Inventory Handlers ---")
if ISInventoryWindowContainerControls_HandlerList then
    for i, h in ipairs(ISInventoryWindowContainerControls_HandlerList) do
        print(i, h.Type)
    end
end

print("--- Loot Handlers ---")
if ISLootWindowContainerControls_HandlerList then
    for i, h in ipairs(ISLootWindowContainerControls_HandlerList) do
        print(i, h.Type)
    end
end
