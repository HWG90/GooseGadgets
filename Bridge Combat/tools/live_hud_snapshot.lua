-- Compact read-only diagnostic. Import does no IO; capture saves metadata only
-- after actor/world/UI identity and the captured fields are rechecked.
local M = {}
local OBSERVERS = {{0x2AA0,0x2AA8,2}, {0x2AC8,0x2AD0,39}, {0x2D40,0x2D48,2}, {0x2D68,0x2D70,2}}
local function d32(b,o)local a,c,d,e=b:byte(o+1,o+4);assert(e,'Short HUD field');return a+c*256+d*65536+e*16777216 end
local function dp(b,o)
    local v=d32(b,o)+d32(b,o+4)*4294967296
    assert(v==0 or(v>=65536 and v<140737488355328),'Unsupported HUD pointer');return v
end
local function hex(b)return(b:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function address(n)return string.format('%X',n)end
function M.capture(tag)
    assert(tag==nil or(type(tag)=='string'and #tag<=48 and tag:match('^[%w_-]+$')),'Use a filename-safe HUD snapshot tag')
    local H=use('hd2_addresses');local A=assert(H.get(),'Address set unavailable')
    assert(A.base==game and A.stamp==0x6AB3B43F,'Unsupported HUD game build')
    local samples,lines={},{}
    local function r(at,size,optional)
        assert(at and at>=65536 and at<140737488355328 and size>=0 and size<=1024,'HUD read out of bounds')
        local b=read(at,size)
        if type(b)~='string'or #b~=size then assert(optional,'HUD memory unreadable at '..address(at));return nil end
        samples[#samples+1]={at=at,size=size,bytes=b};return b
    end
    local function p(at,optional)local b=r(at,8,optional);if not b then return nil end;local v=dp(b,0);assert(optional or v~=0,'HUD pointer absent');return v~=0 and v or nil end
    local function n(at,optional)local b=r(at,4,optional);return b and d32(b,0)or nil end
    local function byte(at,optional)local b=r(at,1,optional);return b and b:byte()or nil end
    local function entry(name,value)lines[#lines+1]=name..'='..tostring(value==nil and 'unavailable'or value)end
    local state,world,player=p(game+A.GAME_STATE),p(game+A.WORLD),p(game+A.PLAYER)
    local scene=n(state+A.STATE_VALUE);assert(scene==3 or scene==4,'HUD scene inactive')
    local avatar,inventory=H.avatar(A);assert(avatar and avatar~=0 and inventory,'Local HUD actor unavailable')
    local local_unit=n(player+0x3A8)
    local pm,ui=p(game+0x3326D20),p(game+0x346D538)
    local row=assert(hashmap(pm+0xF8,avatar),'HUD player row absent')
    local live_count=n(pm+0x70)
    assert(live_count>0 and live_count<=4096 and row>=0 and row<live_count,'HUD player row bounds differ')
    local descriptor=p(pm+0x110+row*8);local desc=r(descriptor,24)
    assert(d32(desc,8)==avatar and desc:byte(21)%2==1,'HUD player descriptor retired')
    local reference=d32(desc,12);local pc=pm+0x53D8B0+row*0x1238
    local roles=r(pc+0xFD0,24);local role3=math.floor(d32(roles,0)/8)%2==1
    entry('scene',scene);entry('avatar',avatar);entry('localUnit',local_unit);entry('bodyRef',reference)
    entry('world',address(world));entry('player',address(player));entry('pm',address(pm));entry('pmPhysicalRow',row)
    entry('pmLiveCount',live_count);entry('descriptor',address(descriptor));entry('descriptorBytes',hex(desc))
    entry('localRole3',role3);entry('localRoleBytes',hex(roles));entry('ui',address(ui))
    local ship,mission=ui+0x46D900,ui+0x24E340
    for _,field in ipairs({{'uiActive',ui}, {'uiInitialized',ui+0x24E334}, {'uiByte24E335',ui+0x24E335},
        {'uiByte24E336',ui+0x24E336}, {'uiByte24E337',ui+0x24E337},
        {'shipActive',ship}, {'shipByte5',ship+5}, {'shipInitialized',ship+0x89778},
        {'missionActive',mission+0x58}, {'missionByte59',mission+0x59}, {'missionByte5A',mission+0x5A},
        {'missionInitialized',mission+0x21F5B0}, {'missionByte21F5B1',mission+0x21F5B1},
        {'missionByte21F5B2',mission+0x21F5B2}, {'missionByte21F5B3',mission+0x21F5B3},
        {'missionByte21F5B4',mission+0x21F5B4}, {'missionByte21F5B5',mission+0x21F5B5},
        {'missionByte21F5B6',mission+0x21F5B6}})do entry(field[1],byte(field[2],true))end
    for _,root in ipairs({{0x820,0x258},{0x930,0x380},{0xA40,0x5D0},{0xB50,0x4A8}})do
        local name='root'..address(root[1]);local parent=p(ui+root[1]+0xF0,true)
        entry(name..'Flags',n(ui+root[1],true));entry(name..'Parent',parent and address(parent)or nil)
        entry(name..'ParentMatches',parent==ui+root[2]);entry(name..'ExpectedParentFlags',n(ui+root[2],true))
    end
    local gui=p(game+0x347CE90,true);entry('gui',gui and address(gui)or nil)
    if gui then
        local depth=n(gui+0x2C5BC,true);entry('guiContextDepth',depth)
        local signed=depth and(depth>=2147483648 and depth-4294967296 or depth)or nil
        -- 12F0974 sign-extends depth; push stores depth+1 and writes
        -- slot[oldDepth+1] at GUI+2C5B9+oldDepth. Empty -1 pushes slot0.
        -- Slots0..3 occupy2C5B8..2C5BB; slot4 would overlap depth2C5BC.
        entry('guiContextDepthSigned',signed)
        entry('guiContextEmpty',signed==-1)
        local slots=r(gui+0x2C5B8,4,true);entry('guiContextSlots',slots and hex(slots)or nil)
        entry('guiContextBoundsKnown',signed~=nil and signed>=-1 and signed<=3)
        entry('guiContextPushWithinBounds',signed~=nil and signed>=-1 and signed<=2)
        entry('guiContextTop',signed and signed>=0 and signed<=3 and byte(gui+0x2C5B8+signed,true)or nil)
    end
    local observer=p(game+0x3326E68,true);entry('observer',observer and address(observer)or nil)
    if observer then
        for _,spec in ipairs(OBSERVERS)do
            local name='observerList'..address(spec[1]);local count=n(observer+spec[1],true)
            entry(name..'Count',count);entry(name..'LayoutCapacity',spec[3]);entry(name..'CountWithinCapacity',count~=nil and count<=spec[3])
            if count and count<=spec[3]and count>0 then
                local records=r(observer+spec[2],count*16,true)
                if records then
                    for index=0,count-1 do
                        entry(name..'Entry'..index..'Object',address(dp(records,index*16)))
                        entry(name..'Entry'..index..'CallbackId',d32(records,index*16+8))
                    end
                else entry(name..'Records','unavailable')end
            end
        end
    end
    local after,inventory_after=H.avatar(A)
    assert(after==avatar and inventory_after==inventory and A.base==game,'HUD actor changed during snapshot')
    assert(p(game+A.GAME_STATE)==state and p(game+A.WORLD)==world and p(game+A.PLAYER)==player
        and p(game+0x3326D20)==pm and p(game+0x346D538)==ui and n(state+A.STATE_VALUE)==scene
        and n(player+0x3A8)==local_unit and hashmap(pm+0xF8,avatar)==row
        and p(pm+0x110+row*8)==descriptor and r(descriptor,24)==desc,'HUD ownership changed during snapshot')
    for _,sample in ipairs(samples)do assert(read(sample.at,sample.size)==sample.bytes,'HUD captured fields changed before save')end
    local filename=string.format('%s-hud-actor-%u-ref-%u-%s%s.txt',scene==4 and 'mission'or 'bridge',avatar,reference,
        os.date('%Y%m%d-%H%M%S'),tag and '-'..tag or '')
    local metadata=table.concat(lines,'\n')
    assert(save_file(filename,metadata)~=false,'HUD snapshot save failed')
    return{filename=filename,scene=scene,avatar=avatar,reference=reference,pm_live_count=live_count,role3=role3,metadata=metadata}
end
return M
