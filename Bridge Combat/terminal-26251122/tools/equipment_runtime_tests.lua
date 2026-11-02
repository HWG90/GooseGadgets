-- 26251122 .11: the Armory swap fatal is the engine refusing to unload a magazine attachment unit that a live unit
-- (left in the world by ship combat) still holds. Combat controls must not arm before the equipment holds are
-- acknowledged; the holds refresh while combat is on, the Armory pause included, and drain in every state.
local function equipment_fixture(held)
    local e={held=held,holds=0,drains=0}
    function e:hold()self.holds=self.holds+1;if self.held then return true end;return false,'Holding the Liberator drum magazine package'end
    function e:drain()self.drains=self.drains+1;return true end
    function e:status()return 'stand-in equipment holds'end
    return e
end
test('combat controls arm only after the equipment holds are acknowledged (.11 Armory swap fatal)',function()
    local e=equipment_fixture(false);local f=fixture({equipment=e})
    yes(f.runtime:set_enabled(true));f.tick(12)
    eq(f.calls['base.apply'],nil,'Combat controls armed before the equipment holds');yes(e.holds>=2,'Holds were not retried')
    yes(f.runtime:status():find('Equipment holds pending',1,true),f.runtime:status())
    e.held=true;f.tick(12)
    yes(f.base.active and f.animation.active and not f.animation.active.restoring,'Combat did not arm once the holds were acknowledged')
    eq(f.calls['base.apply'],1);eq(f.animation:status(),'Bridge animation active');yes(e.drains>=1,'Holds never drained')
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil)
end)
test('equipment holds refresh while combat runs and in the Armory pause, and drain with combat off',function()
    local e=equipment_fixture(true);local n=native_menu_fixture();local f=fixture({one_shot=true,weapon_menu=n,equipment=e});n.record=f.record
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
    f.enable();yes(f.runtime.latched);local before=e.holds
    f.tick(30);yes(e.holds>=before+2,'Holds were not refreshed while combat was latched')
    lost=true;local paused=e.holds;f.tick(30);yes(e.holds>=paused+2,'Holds were not refreshed in the Armory pause')
    eq(f.calls['base.restore'],nil,'The Armory pause tore down combat controls')
    lost=false;f.tick(30);yes(f.runtime.latched and f.animation.active)
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil)
    local holds,drains=e.holds,e.drains;f.tick(50)
    eq(e.holds,holds,'Holds were requested with combat off');yes(e.drains>=drains+2,'Holds did not drain with combat off')
end)
test('a refused equipment hold never tears down combat that is already armed',function()
    local e=equipment_fixture(true);local f=fixture({equipment=e});f.enable();local applies=f.calls['base.apply']
    e.held=false;f.tick(30);yes(f.base.active and f.animation.active);eq(f.calls['base.restore'],nil);eq(f.calls['base.apply'],applies)
    yes(f.runtime:set_enabled(false));f.tick(20);eq(f.base.active,nil)
    yes(f.runtime:set_enabled(true));f.tick(12);eq(f.calls['base.apply'],applies,'Combat re-armed without acknowledged holds')
    e.held=true;f.tick(12);eq(f.calls['base.apply'],applies+1)
end)
