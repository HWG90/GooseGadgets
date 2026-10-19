-- Compile and structure contracts for the assembled BSL startup. No game
-- process attached; the file is only parsed, never executed.
local root = assert(BRIDGE_COMBAT_TEST_ROOT, 'Test root is unavailable')
local path = root .. '/dist/releases/bridge-combat-0.1.16-experimental-bsl-review/BridgeCombat-0.1.16-BSL-startup.lua'
local file = assert(io.open(path, 'rb'), 'Assembled BSL startup is unavailable')
local data = file:read('*a'); file:close()
local passed = 0
local function contract(name, ok)
    assert(ok ~= false, 'contract failed: ' .. tostring(name))
    passed = passed + 1
end

contract('startup parses as LuaJIT source', loadstring(data, '@BridgeCombat-0.1.16-BSL-startup.lua') ~= nil)
contract('no template markers remain', data:find('__MODULES__', 1, true) == nil
    and data:find('__NATIVE_HEX__', 1, true) == nil
    and data:find("'__VERSION__'", 1, true) == nil
    and data:find("'__NATIVE_ASSET__'", 1, true) == nil
    and data:find("'__NATIVE_SHA256__'", 1, true) == nil)
contract('discovery header intact', data:sub(1, #'-- HD2-Addon: mods/goose/bridge_combat_014/startup')
    == '-- HD2-Addon: mods/goose/bridge_combat_014/startup')
local count, bridge_module = 0, false
for _ in data:gmatch("sources%['src/[%.%w_-]+%.lua%'%]") do count = count + 1 end
contract('43 embedded src modules', count == 43)
for name in data:gmatch("sources%['([%.%w_/-]+%.lua)'%]") do
    if name == 'src/terminal_services.lua' then bridge_module = true end
end
contract('bridge module embedded', bridge_module)
local hex = data:match("local NATIVE_HEX = '(%x+)'\n")
local sha = data:match("'(" .. string.rep('%x', 64) .. ")'")
contract('embedded native hex present and even length', hex ~= nil and #hex % 2 == 0 and #hex > 200000)
contract('embedded native sha256 well formed', sha ~= nil and #sha == 64)
local asset_hash = data:match("'native/BridgeCombatWeaponMenu%-(%x+)%.dll'")
contract('native asset name matches embedded sha prefix', asset_hash == sha:sub(1, 12))
contract('startup mentions Mod Options entry', data:find('terminal WEAPONS FREE switch', 1, true) ~= nil)
print('bsl_startup_compile_fixture: ' .. passed .. ' contracts passed; no game process attached')
