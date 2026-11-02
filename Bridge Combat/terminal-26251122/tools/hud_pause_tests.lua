
-- 26251122 .8: the Armory replaces the HUD, the native weapon menu is lost with no ship menu open, and a weapon
-- swap there unloads equipment packages the clip leases ran through (engine fatal, 2026-10-31). The animation
-- must release its pose and leases while the menu is lost, then re-initialize and latch again with the menu.
test('losing the native weapon menu outside a ship menu pauses the animation and resumes with it',function()
    local n=native_menu_fixture();local f=fixture({one_shot=true,weapon_menu=n});n.record=f.record
    local lost=false
    n.update_settled=function()if lost then n.clean=true;return false,'Armory replaced the HUD'end;return true end
    function n:update(enabled,view)
        if lost then self.clean=true;return false,'Native weapon menu retired; waiting for fresh acquisition'end
        if enabled and view and view.ready then
            if self.clean then self.clean=false;self.acquires=self.acquires+1;f.record('native.acquire')end
            return true
        end
        return self:shutdown()
    end
    f.enable();yes(f.runtime.latched);local applies=f.calls['base.apply']
    lost=true;f.tick(12)
    eq(f.animation.active,nil,'Animation still active in the Armory');eq(f.held,false,'Clip leases still held in the Armory')
    yes(f.calls['pose.restore'],'Pose not restored in the Armory');yes(f.calls['clips.release'],'Clips not released in the Armory')
    yes(f.animation:status():find('Native weapon menu unavailable',1,true),f.animation:status())
    eq(f.calls['base.restore'],nil,'Combat controls were torn down for a HUD pause');yes(f.base.active)
    local restores=f.calls['pose.restore'];f.tick(30);eq(f.calls['pose.restore'],restores,'Pause repeated restoration')
    lost=false;f.tick(30)
    yes(f.runtime.enabled and f.runtime.latched and f.base.active,'Combat did not latch again after the menu returned')
    eq(n.acquires,2);yes(f.animation.active and not f.animation.active.restoring);eq(f.animation:status(),'Bridge animation active')
    eq(f.calls['base.apply'],applies,'Combat controls were reapplied after a HUD pause')
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil);eq(f.animation.active,nil)
end)
test('a menu loss on an unreadable observation still pauses once the actor reads again',function()
    local n=native_menu_fixture();local f=fixture({one_shot=true,weapon_menu=n});n.record=f.record
    local lost=false
    n.update_settled=function()if lost then n.clean=true;return false,'Armory replaced the HUD'end;return true end
    function n:update(enabled,view)
        if lost then self.clean=true;return false,'Native weapon menu retired; waiting for fresh acquisition'end
        if enabled and view and view.ready then
            if self.clean then self.clean=false;self.acquires=self.acquires+1;f.record('native.acquire')end
            return true
        end
        return self:shutdown()
    end
    f.enable();yes(f.runtime.latched)
    lost=true;f.unknown=true;f.tick(3);f.unknown=false;f.tick(12)
    eq(f.animation.active,nil,'Animation still active after the observation returned');eq(f.held,false)
    lost=false;f.tick(30);yes(f.runtime.latched and f.animation.active);eq(f.animation:status(),'Bridge animation active')
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil)
end)
test('losing the native weapon menu while a ship menu is open keeps the one-shot pose (ESC)',function()
    local n=native_menu_fixture();local f=fixture({one_shot=true,weapon_menu=n});n.record=f.record
    n.update_settled=function()if not f.menu then n.clean=true;return false,'ESC retired UI'end;return true end
    f.enable();yes(f.runtime.latched);local captures=f.calls['pose.capture']
    f.menu=false;f.tick(60);yes(f.runtime.latched and f.animation.active);eq(f.calls['pose.restore'],nil)
    f.menu=true;f.tick(12);yes(f.runtime.latched);eq(f.calls['pose.capture'],captures);eq(n.acquires,2)
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil)
end)
-- 26251122 .10 (2026-11-01 19:53Z crash with .9): the Armory's rebuilt menu is acquirable on the very next step after
-- it retires. The .9 half-second debounce never elapsed, so the pose and its leases survived into the weapon swap.
-- The pause must fire on the first lost step and release the leases before the menu is acquired again.
test('a menu that is acquirable again right after retiring still releases the leases first (.9 Armory crash)',function()
    local n=native_menu_fixture();local f=fixture({one_shot=true,weapon_menu=n});n.record=f.record
    local retire=false
    n.update_settled=function()if retire then n.clean=true;return false,'Armory replaced the HUD'end;return true end
    function n:update(enabled,view)
        if retire then retire=false;self.clean=true;return false,'Native weapon menu retired; waiting for fresh acquisition'end
        if enabled and view and view.ready then
            if self.clean then self.clean=false;self.acquires=self.acquires+1;f.record('native.acquire')end
            return true
        end
        return self:shutdown()
    end
    f.enable();yes(f.runtime.latched);eq(n.acquires,1);eq(f.calls['clips.release'],nil)
    retire=true;f.tick(60)
    local function at(name,nth)local k=0;for i,e in ipairs(f.events)do if e==name then k=k+1;if k==nth then return i end end end end
    yes(at('clips.release',1),'Clip leases were never released around the HUD replacement')
    eq(n.acquires,2);yes(at('native.acquire',2)>at('clips.release',1),'The rebuilt menu was acquired before the leases were released')
    yes(f.calls['pose.restore'],'Pose not restored around the HUD replacement');eq(f.calls['base.restore'],nil)
    yes(f.runtime.latched and f.animation.active and not f.animation.active.restoring);eq(f.animation:status(),'Bridge animation active')
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil);eq(f.animation.active,nil)
end)
