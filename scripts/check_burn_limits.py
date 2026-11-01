"""Temporary limiter persistence/boot restoration using actual source helpers."""
import copy
import re
from types import SimpleNamespace as NS

import check_relay_constellation as harness
import check_survey_orbit as orbit
from check_codebase import ROOT,function_body
from check_espoir_fleet import Items,Text
from check_espoir_fleet import native

LIMITS=(ROOT/'lib/burn_limits.ks').read_text()
BURN=(ROOT/'lib/maneuver.ks').read_text()
BOOT=(ROOT/'lib/boot_lib.ks').read_text()


def fixture():
    env,ship,saved,events,_,_,_=orbit.fixture()
    engines=Items([NS(UID=101,THRUSTLIMIT=100),NS(UID=102,THRUSTLIMIT=50),NS(UID=103,THRUSTLIMIT=0)])
    ship.ENGINES=engines
    env.update(_sma=lambda:20*engines[0].THRUSTLIMIT/100+10*engines[1].THRUSTLIMIT/100,
        _nf=lambda n:abs(n)<1e30,BURN_MIN_FULL_THRUST_SECONDS=2,
        bootLibLoad=lambda name:events.append(str(name)))
    for name in re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',LIMITS):
        env[name]=lambda *args,name=name:harness.invoke(LIMITS,name,env,*args)
    return env,ship,saved,events,engines


def check_snapshot_and_boot():
    env,ship,saved,events,engines=fixture()
    fraction=harness.invoke(BURN,'_burnLimitThrust',env,.0124)
    assert 0<fraction<.001 and [e.THRUSTLIMIT for e in engines]==[100*fraction,50*fraction,0]
    snapshot=copy.deepcopy(saved['engine_thrust_restore'])
    assert [row['LIMIT'] for row in snapshot]==[100,50,0]
    assert not env['burnThrustSave']() and saved['engine_thrust_restore']==snapshot
    # Reboot with reordered engines, a separated engine and an unrelated new
    # engine. Only original UIDs recover their exact settings, including0.
    new=NS(UID=999,THRUSTLIMIT=37)
    ship.ENGINES=Items([engines[2],new,engines[1]])
    harness.invoke(BOOT,'bootPreamble',env)
    assert [e.THRUSTLIMIT for e in ship.ENGINES]==[0,37,50]
    assert 'engine_thrust_restore' not in saved and events[:2]==['core','burn_limits']
    assert env['burnThrustRestore']() # Idempotent; no blanket100% setting.
    assert 'LOCAL FUNCTION _stl' not in BURN
    print('PASS: actual tiny-burn limiter saves original100/50/0 before mutation; boot restores by UID across reorder/separation, leaves new engines alone and cannot overwrite its pending snapshot')


def check_physical_controls_and_integration():
    for key in ('thrust','raw','pilot','active'):
        env,ship,saved,_,engines=fixture();assert env['burnThrustSave']()
        for eng in engines:eng.THRUSTLIMIT=0
        if key=='thrust':ship.THRUST=.1
        if key=='raw':ship.CONTROL.MAINTHROTTLE=.1
        if key=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if key=='active':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        assert not env['burnThrustRestore']() and 'engine_thrust_restore' in saved
        assert all(eng.THRUSTLIMIT==0 for eng in engines)
        # Attempt-reset commands must not erase deferred hardware recovery.
        saved['burn_pending']=Text('true')
        for name in list(saved):
            if name.startswith('burn_'):del saved[name]
        assert 'engine_thrust_restore' in saved
        ship.THRUST=0;ship.CONTROL.MAINTHROTTLE=0;ship.CONTROL.PILOTMAINTHROTTLE=0
        env['KUNIVERSE'].ACTIVEVESSEL=ship
        assert env['burnThrustRestore']() and [eng.THRUSTLIMIT for eng in engines]==[100,50,0]
    execute=function_body(BURN,'executeManeuver')
    assert execute.index('burnThrustRestore()')<execute.index('_burnLimitThrust(bdv)')
    assert execute.count('burnThrustRestore()')==5
    assert 'engine_thrust_restore' not in function_body(BURN,'_cpb') # Separate durable restore intent.
    assert 'bootLibLoad("burn_limits")' in function_body(BOOT,'bootPreamble')
    print('PASS: restoration refuses nonzero/invalid controls or inactive craft and retains intent; normal/failure/missed-window executor exits share exact restoration and boot recovers interrupted preparation')


def check_explicit_legacy_repair_command():
    command=(ROOT/'cmd/enginelimits.ks').read_text()
    for fault in ('none','status','abort','warp','thrust','pilot','started','zero','too-high'):
        env,ship,saved,events,engines=fixture()
        for eng in engines:eng.THRUSTLIMIT*=.000347
        before=[eng.THRUSTLIMIT for eng in engines]
        ship.DELTAV.FORCECALC=lambda:events.append('recalc')
        env.update(limitPercent=native(100),RUNPATH=lambda *_:None,bootPreamble=lambda:None)
        if fault=='status':env['limitPercent']=native(-1)
        if fault=='abort':env['ABORT']=True
        if fault=='warp':env['WARP']=1
        if fault=='thrust':ship.THRUST=.1
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='started':saved['burn_started']=Text('true')
        if fault=='zero':env['limitPercent']=native(0)
        if fault=='too-high':env['limitPercent']=native(101)
        state_before=saved.copy()
        harness.invoke(command,'_cmdEngineLimits',env)
        assert [eng.THRUSTLIMIT for eng in engines]==([100,100,0] if fault=='none' else before)
        assert saved==state_before and events==(['recalc'] if fault=='none' else [])
    print('PASS: explicit legacy100% command repairs every remaining nonzero-limit engine including future stages, preserves disabled engines and all mission state; unsafe controls, flown burns and invalid values refuse mutation')


if __name__=='__main__':
    check_snapshot_and_boot()
    check_physical_controls_and_integration()
    check_explicit_legacy_repair_command()
