-- Review diagnostic: use the maintained, guarded game back-buffer capture.
-- No desktop capture or Photo Mode activation occurs here.
local M = {}
local function up(fn, key)
    if type(fn) ~= 'function' then return end
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then return end
        if name == key then return value end
    end
end
function M.capture(path)
    assert(type(path) == 'string' and path:match('^[A-Za-z]:[/\\]') and path:sub(-4) == '.dds',
        'Use an absolute review DDS path')
    local fn, controller = rawget(_G, 'render')
    for _ = 1, 20 do
        if type(fn) ~= 'function' then break end
        controller = up(up(fn, 'bindings_step'), 'DBF_FREECAM')
        if controller then break end
        fn = up(fn, 'previous') or up(fn, 'original')
    end
    assert(controller, 'Maintained game capture runtime is unavailable')
    local photo = assert(up(controller.tick, 'photo'))
    assert(photo.active == false, 'Close Photo Mode before this bridge diagnostic')
    local tick = up(controller.tick, 'original_tick') or controller.tick
    local screenshots = assert(up(controller.request_screenshot, 'screenshots') or up(tick, 'screenshots'),
        'Game capture controller is unavailable')
    assert(not screenshots.active(), 'Another game capture is pending')
    local backend = assert(up(screenshots.tick, 'backend'))
    local convert = assert(up(screenshots.tick, 'convert'))
    local ok, meta = backend.capture(path)
    assert(ok, meta)
    local png = path:sub(1, -5) .. '.png'
    local converted, why = convert(path, png, meta)
    assert(converted, why)
    return png, meta.color_encoding, meta.width, meta.height
end
return M
