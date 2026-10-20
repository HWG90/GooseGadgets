local Compat=dofile(assert(NATIVE_ADS_TEST_ROOT)..'/src/camera_compat.lua')
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1 end
local function equal(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function fixture(previous)
    local input_reader=previous
    local provider={held=false,available=true,sets=0,acquires=0,releases=0}
    function provider.set_input_blocked(fn)
        provider.sets=provider.sets+1
        if provider.fail_before then error('fixture setter before change')end
        input_reader=fn
        if provider.fail_after then error('fixture setter after change')end
    end
    function provider.acquire()provider.acquires=provider.acquires+1;error('Photo lease must never be acquired')end
    function provider.release()provider.releases=provider.releases+1;error('Photo lease must never be released')end
    local c={enabled=false};function c:is_enabled()if self.failure then error('fixture controller error')end;return self.enabled end
    local G={debug=debug,DBF_PHOTO_ACTIONCAM_COMPAT=provider}
    local compat=Compat.new(c,nil,G)
    local function current()return input_reader end
    return compat,c,provider,G,current
end
test('public reader chain blocks only enabled FPV and never takes a Photo lease',function()
    local calls=0;local prior=function()calls=calls+1;return false end
    local a,c,p,_,current=fixture(prior)
    assert(a:prepare());local shim=current();assert(shim~=prior);equal(shim(),false)
    c.enabled=true;equal(shim(),true);equal(calls,2);assert(a:update());equal(p.sets,1)
    c.enabled=false;assert(a:update());equal(current(),prior);assert(a:is_clean())
    equal(p.acquires,0);equal(p.releases,0);equal(prior(),false)
end)
test('nil prior callback retains legacy behavior and exact stop restoration',function()
    local a,c,_,_,current=fixture();c.enabled=true;assert(a:prepare());equal(current()(),true)
    assert(a:stop());equal(current(),nil);assert(a:is_clean());equal(a:result().blocking,false)
end)
test('Photo held is foreign before installation and existing chain yields without closing it',function()
    local prior=function()return false end
    local a,c,p,_,current=fixture(prior);c.enabled=true;p.held=true
    assert(a:foreign());assert(not a:prepare());assert(a:update());equal(p.sets,0);equal(current(),prior)
    p.held=false;assert(a:update());local shim=current();equal(shim(),true)
    p.held=true;assert(a:foreign());equal(shim(),false);assert(a:update());equal(shim(),false)
    equal(p.held,true);equal(p.acquires,0);equal(p.releases,0)
    p.held=false;assert(a:update());equal(shim(),true);assert(a:shutdown());equal(current(),prior)
end)
test('prior true error and nonboolean results remain conservatively blocked',function()
    for _,prior in ipairs({function()return true end,function()error('previous reader failed')end,
        function()return nil end,function()return 0 end,function()return 'false'end})do
        local a,c,p,_,current=fixture(prior);c.enabled=true;assert(a:prepare())
        p.held=true;equal(current()(),true);assert(a:stop());equal(current(),prior)
    end
end)
test('foreign reader replacement is preserved and cannot be overridden while enabled',function()
    local prior=function()return false end
    local a,c,p,_,current=fixture(prior);c.enabled=true;assert(a:prepare());local shim=current()
    local replacement=function()return shim()end;p.set_input_blocked(replacement)
    assert(a:foreign());assert(not a:update());equal(current(),replacement);equal(shim(),false)
    assert(not a:prepare());equal(current(),replacement)
    assert(a:stop());equal(current(),replacement);equal(shim(),false);assert(a:is_clean())
    assert(a:prepare());assert(current()~=replacement);assert(a:stop());equal(current(),replacement)
end)
test('provider replacement fails closed and cleans only its retained original setter',function()
    local prior=function()return false end
    local a,c,p,G,current=fixture(prior);c.enabled=true;assert(a:prepare())
    local other_input
    local other={held=false,available=true,set_input_blocked=function(fn)other_input=fn end}
    G.DBF_PHOTO_ACTIONCAM_COMPAT=other
    assert(a:foreign());assert(not a:update());equal(other_input,nil)
    assert(a:stop());equal(current(),prior);equal(other_input,nil);equal(p.acquires,0);equal(p.releases,0)
end)
test('setter exceptions preserve a verifiable cleanup record without touching foreign ownership',function()
    for _,when in ipairs({'before','after'})do
        local prior=function()return false end
        local a,c,p,_,current=fixture(prior);c.enabled=true;p['fail_'..when]=true
        assert(not a:prepare());assert(a:foreign())
        if when=='after'then
            p.fail_after=false;p.fail_before=true;assert(not a:stop());equal(a:result().cleanup_pending,true)
            p.fail_before=false
        else p.fail_before=false end
        assert(a:stop());equal(current(),prior);assert(a:is_clean());equal(p.acquires,0);equal(p.releases,0)
    end
end)
test('shutdown restores only the owned reader and refuses new preparation',function()
    local prior=function()return false end
    local a,c,p,_,current=fixture(prior);c.enabled=true;assert(a:prepare());p.fail_before=true
    assert(not a:shutdown());assert(not a:prepare());equal(a:result().cleanup_pending,true)
    p.fail_before=false;assert(a:shutdown());equal(current(),prior);assert(a:is_clean())
end)
test('absent Photo integration works while malformed or uninspectable providers fail closed',function()
    local a,c,_,G=fixture();c.enabled=true;G.DBF_PHOTO_ACTIONCAM_COMPAT=nil
    equal(a:foreign(),false);assert(a:prepare());assert(a:update());assert(a:is_clean())
    for _,bad in ipairs({true,{held=false},{held='false',set_input_blocked=function()end},
        {held=false,set_input_blocked=function()end}})do
        G.DBF_PHOTO_ACTIONCAM_COMPAT=bad;assert(a:foreign());assert(not a:prepare());assert(a:stop())
    end
    local b,bc,_,BG=fixture();bc.enabled=true;BG.debug={getupvalue=function()error('fixture debug unavailable')end}
    -- Debug capability is captured at construction, as in the real loader.
    b=Compat.new(bc,nil,BG);assert(not b:prepare());assert(b:foreign())
end)
test('recursive previous readers are bounded and controller failures block conservatively',function()
    local current
    local a,c,p,_,get=fixture(function()return current()end);c.enabled=true;assert(a:prepare());current=get()
    equal(current(),true);assert(a:stop())
    a,c,p,_,get=fixture(function()return false end);assert(a:prepare());c.failure=true;equal(get()(),true)
    c.failure=false;assert(a:stop())
end)
test('a positively loaded ActionCam without its sharing bridge is foreign',function()
    local a,c,p,G=fixture();c.enabled=true
    G.DBF_PHOTO_ACTIONCAM_COMPAT=nil;G.package={loaded={['mods/actioncam/actioncam']=true}}
    local foreign,why=a:foreign();equal(foreign,true);assert(why:find('bridge unavailable'))
    assert(not a:prepare());assert(not a:update());equal(p.sets,0);equal(p.acquires,0);equal(p.releases,0)
    assert(a:stop());G.package.loaded['mods/actioncam/actioncam']=false
    equal(a:foreign(),false);assert(a:prepare());assert(a:is_clean())
end)

local function local_fixture()
    local calls={external=0,debug=0}
    local function forbidden()
        calls.external=calls.external+1
        error('A local Photo camera lease must only be observed')
    end
    local owner={available=true,held=false,count=0,acquire=forbidden,release=forbidden,dispose=forbidden,refresh=forbidden}
    local c={enabled=true};function c:is_enabled()return self.enabled end
    local G={DBF_PHOTO_CAMERA_OWNERSHIP=owner,
        DBF_PHOTO_ACTIONCAM_COMPAT=setmetatable({},{__index=forbidden}),
        package={loaded={['mods/actioncam/actioncam']=true}},
        debug={getupvalue=function()calls.debug=calls.debug+1;error('Local Photo ownership has no callback chain')end}}
    return Compat.new(c,nil,G),c,owner,G,calls
end

test('local Photo lease takes precedence over a loaded legacy module and never invokes foreign APIs',function()
    local a,c,p,G,calls=local_fixture()
    equal(a:foreign(),false);assert(a:prepare());assert(a:is_clean())
    -- Constant field reads are sufficient: unchanged updates never inspect or
    -- rebuild a reader chain, acquire a lease, or call a foreign refresh API.
    for _=1,120 do
        assert(a:update());equal(a:foreign(),false)
        local result=a:result();equal(result.foreign,false);equal(result.blocking,false)
    end
    equal(calls.external,0);equal(calls.debug,0)
    equal(p.available,true);equal(p.held,false);equal(p.disabled,nil);equal(p.count,0)
    c.enabled=false;assert(a:update());assert(a:stop());assert(a:shutdown());assert(a:is_clean())
    equal(G.DBF_PHOTO_CAMERA_OWNERSHIP,p);equal(calls.external,0);equal(calls.debug,0)
end)

test('local Photo held transitions yield immediately without stealing or releasing its lease',function()
    local a,c,p,_,calls=local_fixture();assert(a:prepare())
    p.held=true;equal(a:foreign(),true);assert(not a:prepare());assert(a:update())
    equal(p.held,true);equal(c.enabled,true);equal(a:result().blocking,false)
    p.held=false;equal(a:foreign(),false);assert(a:update());assert(a:prepare())
    equal(calls.external,0);equal(calls.debug,0)
    p.held=true;assert(a:stop());assert(a:shutdown());equal(p.held,true)
    equal(calls.external,0);assert(a:is_clean())
end)

test('local lease replacement is observed directly and its new held state wins',function()
    local a,_,old,G,calls=local_fixture();assert(a:prepare())
    local replacement={available=true,held=true}
    G.DBF_PHOTO_CAMERA_OWNERSHIP=replacement
    equal(a:foreign(),true);assert(a:update());assert(not a:prepare())
    equal(old.held,false);equal(replacement.held,true)
    replacement.held=false;equal(a:foreign(),false);assert(a:prepare());assert(a:update())
    equal(a:result().foreign,false);assert(a:stop());equal(calls.external,0);equal(calls.debug,0)
end)

test('malformed or unavailable local advertisements fail closed without falling back to legacy hooks',function()
    for _,bad in ipairs({false,true,{held=false},{available=true},{available=true,held='false'},
        {available=false,held=false},{available=true,held=false,disabled=true}})do
        local a,_,p,G,calls=local_fixture();G.DBF_PHOTO_CAMERA_OWNERSHIP=bad
        equal(a:foreign(),true);assert(not a:prepare());assert(not a:update());assert(a:stop())
        equal(calls.external,0);equal(calls.debug,0);equal(p.held,false)
    end
end)

test('switching from an owned legacy chain to a local lease restores only the retained legacy reader',function()
    local prior=function()return false end
    local a,c,p,G,current=fixture(prior);c.enabled=true;assert(a:prepare());local shim=current()
    local external=0
    local function forbidden()external=external+1;error('Foreign Photo lease invoked')end
    local owner={available=true,held=false,acquire=forbidden,release=forbidden,dispose=forbidden}
    G.DBF_PHOTO_CAMERA_OWNERSHIP=owner
    assert(a:foreign());assert(not a:update());equal(shim(),false)
    p.fail_before=true;assert(not a:stop());equal(a:result().cleanup_pending,true)
    equal(current(),shim);equal(owner.held,false);equal(external,0)
    p.fail_before=false;assert(a:stop());equal(current(),prior);assert(a:is_clean())
    equal(a:foreign(),false);assert(a:prepare());assert(a:update())
    equal(current(),prior);equal(p.sets,3);equal(external,0)
end)

test('removing the local advertisement reuses the unchanged legacy reader ownership contract',function()
    local prior=function()return false end
    local a,c,p,G,current=fixture(prior);c.enabled=true
    G.DBF_PHOTO_CAMERA_OWNERSHIP={available=true,held=false}
    assert(a:prepare());equal(current(),prior);equal(p.sets,0)
    G.DBF_PHOTO_CAMERA_OWNERSHIP=nil
    assert(a:prepare());assert(current()~=prior);equal(p.sets,1)
    assert(a:stop());equal(current(),prior);equal(p.sets,2)
end)
print('Native ADS camera compatibility fixtures: '..passed..' passed')
