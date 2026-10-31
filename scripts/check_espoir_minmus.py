"""Local excursion intent/checkpoint/reboot regressions; no native flight VM."""
import math
from types import SimpleNamespace as NS

import check_entry_landing as entry
import check_espoir_fleet as fleet
from check_codebase import ROOT,dependency_tables,closure,function_body,command_entrypoint_errors
from check_minmus_kolniya import execute
from check_surface_return import read_settings

SOURCE=(ROOT/'lib/excursion.ks').read_text()
# The source harness does not implement implicit scalar/string coercion.
SOURCE=SOURCE.replace('LOCAL lat IS 999.','LOCAL lat IS fixtureScalar().').replace('LOCAL lng IS 999.','LOCAL lng IS fixtureScalar().')


def fixture(surface=False,profile='minmus_lander'):
    env,ship,state,events=entry.fixture()
    ship.BODY=NS(NAME='Minmus',RADIUS=60000,MU=1.7658e9,SOIRADIUS=2247428,ATM=NS(EXISTS=False))
    ship.STATUS='LANDED' if surface else 'ORBITING';ship.ALTITUDE=3000 if surface else 15000
    ship.PERIAPSIS=ship.APOAPSIS=15000
    ship.ORBIT=NS(HASNEXTPATCH=False,ECCENTRICITY=0,INCLINATION=90)
    ship.VELOCITY.SURFACE=NS(MAG=0)
    ship.DELTAV=NS(VACUUM=1800)
    ship.MASS=1;ship.AVAILABLETHRUST=2
    state.update(vehicle='Espoir',mission_id=profile,phase='DONE',launch_time=fleet.native(1000),
        shape_budget_id='Minmus:1000',shape_budget_spent=70,science_flight_samples='preserved')
    updates={};world=dict(waypoint=0,loaded=True)
    env.update(fleet.profile(profile),EXCURSION_RESERVE_DV=300,HASNODE=False,
        LIST=lambda *xs:fleet.Items(xs),LEXICON=lambda *xs:fleet.Map(zip(xs[::2],xs[1::2])),
        fixtureScalar=lambda:fleet.native(999),getTarget=lambda:ship.BODY.NAME,
        launchSeq=fleet.Items(),
        selectedWaypoint=lambda:world['waypoint'],
        missionOverrideUpdate=lambda values:updates.update(values),
        stateSet=lambda key,value:state.update({key:value}),
        phaseBandForPhase=lambda phase:'PRELAUNCH' if phase=='PRELAUNCH' else 'EXCURSION',
        stateSaveReloadState=lambda reason,phase,band:state.update(phase=phase,reload_reason=reason,reload_next_band=band),
        landingOrbitContext=lambda:ship.BODY.NAME+':'+state['mission_id']+':1000',
        yieldToPrompt=lambda:events.append('hold'),nextPhase=lambda *_:events.append('advance'),
        bootPreamble=lambda:None,bootLibLoad=lambda *_:None,RUNPATH=lambda *_:None,
        HOMECONNECTION=NS(ISCONNECTED=True),bootApplyMissionConfig=lambda *_:world['loaded'])
    env['STAGE'].DELTAV.VACUUM=1200
    for name in ('excursionIdle','excursionOrbitSafe','excursionSelect','phaseExcursionReady'):
        env[name]=lambda *args,name=name:entry.call(SOURCE,name,env,*args)
    return env,ship,state,events,updates,world


def check_profiles_and_scanner_handoff():
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    survey=fleet.profile('minmus_orbital_surveyor');land=fleet.profile('minmus_lander')
    assert [survey['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[1041045,465764,21.6,255.5,157.3]
    assert survey['CAPTURE_PE']==465764 and survey['CAPTURE_INC']==21.6 and survey['CAPTURE_LAN']==-1
    assert survey['SEQUENCE'][-3:]==['SHAPE','SCIENCE_OPS','DONE']
    assert survey['SCIENCE_OPS_HOLD']==1 and survey['SCIENCE_OPS_RUN_ALL']==0
    assert 'SCANSAT_OPS' not in survey['SEQUENCE'] # Operator confirms contract first.
    assert land['CAPTURE_PE']==land['SHAPE_AP']==land['SHAPE_PE']==15000
    assert land['CAPTURE_INC']==land['SHAPE_INC']==90
    assert land['SEQUENCE'][-5:]==['LANDING_REVIEW','LAND_DEORBIT','LAND_ASSIST','SURFACE_SCIENCE','DONE']
    for cfg in (survey,land):
        assert cfg['TARGET_']=='MINMUS' and cfg['MISSION_TYPE']=='kerbin_moon'
        assert cfg['MISSION_EXCURSIONS']==cfg['MISSION_CACHE_NEXT_BAND']==1 and cfg['COAST_AUTO_WARP']==0
        assert cfg['SHAPE_RESERVE_DV']==cfg['EXCURSION_RESERVE_DV']==300
        for phase in cfg['SEQUENCE']:assert phase.lower() in phases and closure(phases[phase.lower()],deps)
    assert land['LANDING_RADIO_MODE']=='AUTO' and land['LANDING_REQUIRE_KERBIN']==1 and land['LANDING_KERBIN_MIN_ELEV']==15
    assert land['LANDING_LIGHT_MODE']=='SUNLIT' and land['LANDING_SUN_MIN_ELEV']==5
    assert land['LANDING_TERRAIN_MAX_SLOPE']==5 and land['LANDING_DIVERT_EMERGENCY_SLOPE']==15
    assert land['TARGET_LOCK']==land['LANDING_AUTO_TARGET']==land['LANDING_FLEXIBLE_SITE']==land['LANDING_ECONOMY_TERMINAL_RETARGET']==0
    assert land['LANDING_CONFIRM_TARGET']==0 # The explicit site command authorizes planning.
    assert land['LANDING_POWERED_LEAD']==land['LANDING_STAGE_BRAKE_CREDIT']==land['LANDING_ECONOMY_BRAKE']==1
    assert land['LANDING_RETURN_DECOUPLER_TAG']==land['LANDING_RELEASE_DECOUPLER_TAG']==''
    assert land['SCIENCE_SURFACE_DWELL']==600
    assert bands['excursion']==['excursion_ready']
    assert not {'maneuver','orbit_shape','launch','landing_main','return_setup'} & closure(phases['excursion_ready'],deps)
    env,_,state,events,updates,_=fixture(profile='minmus_orbital_surveyor')
    env['opts']=fleet.native(dict(after='scan'))
    entry.call((ROOT/'cmd/orbit.ks').read_text(),'_cmdOrbit',env)
    assert state['phase']=='EXCURSION_READY' and not events
    assert [updates['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[70000,70000,90,-1,-1]
    assert updates['SCANSAT_DECOUPLER_TAG']=='' and updates['SCANSAT_DISPOSE_CARRIER']==updates['SCANSAT_AUTO_DEORBIT']==0
    assert updates['SCANSAT_DISPOSE_BEFORE_RELEASE']==updates['SCANSAT_STAGE_AFTER_RELEASE']==0
    assert updates['SCANSAT_POWER_GUARD']==1 and updates['SCANSAT_POWER_LOW']==.3 and updates['SCANSAT_POWER_RESUME']==.6
    assert updates['SEQUENCE']==['EXCURSION_READY','SHAPE','SCANSAT_OPS','DONE']
    # Execute the real override literal and parse it into a fresh profile.
    fresh=read_settings('\n'.join('SET '+key+' TO '+str(fleet.literal(value))+'.' for key,value in updates.items()),dict(survey))
    assert fresh['SHAPE_INC']==90 and fresh['SHAPE_AOP']==fresh['SHAPE_LAN']==-1
    assert fresh['SHAPE_TOTAL_DV_CAP']==survey['SHAPE_TOTAL_DV_CAP'] and fresh['SHAPE_RESERVE_DV']==300
    assert fresh['SCANSAT_REQUIRED_TYPES']==survey['SCANSAT_REQUIRED_TYPES']
    assert state['shape_budget_spent']==70 and state['mission_id']==survey['MISSION_ID']
    print('PASS: exact contract orbit precedes manual polar-mapping command; fresh overrides keep scanners/probe together, precision, fuel ledgers, original identity, no autowarp and ordinary lean band handoffs')


def check_surface_relaunch_and_visit_checkpoint():
    # Custom orbit excursion clears old apsidal/plane constraints without
    # rewriting into a Kerbin return or weakening the existing SHAPE budget.
    for surface in (False,True):
        env,_,state,events,updates,_=fixture(surface)
        env['opts']=fleet.native(dict(ap=659734,pe=554472,inc=0,aop=.4))
        entry.call((ROOT/'cmd/orbit.ks').read_text(),'_cmdOrbit',env)
        assert [updates['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[659734,554472,0,-1,.4]
        assert updates['SEQUENCE'][-2:]==['SCIENCE_OPS','DONE'] and not events
        assert not any(key in updates for key in ('SHAPE_TOTAL_DV_CAP','SHAPE_RESERVE_DV','MISSION_ID','TARGET_'))
        assert state['shape_budget_spent']==70 and state['mission_id']=='minmus_lander'
        if surface:assert updates['PARKING_ALT']==15000 and updates['LAUNCH_INCLINATION']==0 and updates['CAPTURE_LAN']==-1
    for surface in (False,True):
        for waypoint in (False,True):
            env,ship,state,events,updates,world=fixture(surface)
            env['opts']=fleet.native(dict(lat=-29.189,lng=17.465))
            if waypoint:
                env['opts']=fleet.Map();world['waypoint']=NS(GEOPOSITION=NS(LAT=fleet.native(-29.189),LNG=fleet.native(17.465)))
            original=state.copy()
            entry.call((ROOT/'cmd/visit.ks').read_text(),'_cmdVisit',env)
            expected=['EXCURSION_READY','SHAPE','LAND_DEORBIT','LAND_ASSIST','SURFACE_SCIENCE','DONE']
            if surface:expected=['PRELAUNCH','LAUNCH','PARK']+expected
            assert updates['SEQUENCE']==expected
            assert not {'XING','CAPTURE','FAIR','ANTS','RETURN_SETUP','SURFACE_RETURN_SETUP'} & set(expected)
            assert updates['SHAPE_PE']==updates['SHAPE_AP']==15000 and updates['SHAPE_INC']==90
            assert updates['TARGET_LOCK']==1 and updates['TARGET_LAT']==-29.189 and updates['TARGET_LNG']==17.465
            assert updates['LANDING_AUTO_TARGET']==updates['LANDING_USE_WAYPOINTS']==updates['LANDING_FLEXIBLE_SITE']==0
            assert not events and state['mission_id']==original['mission_id'] and state['launch_time']==1000
            assert not state.get('surface_visit') # Published at the post-ascent checkpoint only.
            if surface:
                assert updates['LAUNCH_PLANE_MODE']=='' and updates['ASCENT_STAGED'] is False
                # Execute the real prelaunch dispatcher: never ask for Minmus's orbit around itself.
                cfg=dict(env,**updates,confirmLaunch=lambda:True,_prelaunchClearPlanState=lambda:None,
                    _prelaunchRdvTarget=lambda:'',launchSeq=fleet.Items(expected),fixture_wait=lambda *_:None)
                def forbidden(*_):raise AssertionError('local ascent attempted an interbody departure')
                cfg.update(_prelaunchToBodyOrbit=forbidden,_prelaunchToInterplanetary=forbidden)
                cfg['_prelaunchNextPhaseIs']=lambda phase:entry.call((ROOT/'lib/prelaunch.ks').read_text(),'_prelaunchNextPhaseIs',cfg,phase)
                entry.call((ROOT/'lib/prelaunch.ks').read_text(),'phasePrelaunch',cfg)
                assert events==['advance'];events.clear()
                # Existing ascent owns its real liftoff clock until parking.
                state['launch_time']=fleet.native(2000)
            ship.STATUS='ORBITING';state['phase']='EXCURSION_READY'
            env['phaseExcursionReady']()
            assert events==['cutoff','advance'] and state['launch_time']==1000
            assert state['shape_budget_spent']==70 and state['shape_budget_id']=='Minmus:1000'
            assert state['surface_visit']==1 and state['excursion']['READY']
            assert state['landing_site_context']==env['landingOrbitContext']()
            assert state['excursion_liftoff']==(2000 if surface else 1000)
            events.clear();env['phaseExcursionReady']() # Reboot between checkpoint and phase handoff.
            assert state['surface_visit']==1 and state['launch_time']==1000 and events==['cutoff','advance']
            state['phase']='DONE';ship.STATUS='LANDED'
            assert env['excursionSelect'](fleet.native(dict(lat=1,lng=2)),True)
            assert state['excursion']['SITE']==2
    print('PASS: surface/orbit waypoints use only local flight phases; real prelaunch avoids interbody timing, post-ascent restores mission epoch without resetting budgets, and checkpoint reboots do not replay/increment visits')


def check_command_and_checkpoint_guards():
    for surface in (False,True):
        for fault in ('abort','node','warp','takeover','thrust','raw','pilot','pending','burn','deorbit','route','identity','disabled',
                      'wrong-phase','atmosphere','motion','patch','pe','ecc','fuel','stage-fuel','twr','mass','reserve',
                      'missing-site','partial-site','nan-site','unknown','string','ap','pe-target','inc','lan','aop','after','profile'):
            env,ship,state,events,updates,world=fixture(surface)
            visit=fault in ('missing-site','partial-site','nan-site')
            opts=fleet.Map() if visit else fleet.native(dict(ap=659734,pe=554472,inc=0,aop=.4))
            if fault=='abort':env['ABORT']=True
            if fault=='node':env['HASNODE']=True
            if fault=='warp':env['WARP']=1
            if fault=='takeover':env['KUNIVERSE'].ACTIVEVESSEL=NS()
            if fault=='thrust':ship.THRUST=1
            if fault=='raw':ship.CONTROL.MAINTHROTTLE=.1
            if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
            if fault in ('pending','burn','deorbit'):state[{'pending':'burn_pending','burn':'burn_started','deorbit':'deorbit_burn_started'}[fault]]='true'
            if fault=='route':state['hop_route_active']=True
            if fault=='identity':state['mission_id']=''
            if fault=='disabled':env['MISSION_EXCURSIONS']=0
            if fault=='wrong-phase':state['phase']='LAND_ASSIST'
            if fault=='atmosphere':ship.BODY.ATM.EXISTS=True
            if fault=='motion':ship.STATUS='SUB_ORBITAL'
            if fault=='patch':ship.ORBIT.HASNEXTPATCH=True;ship.STATUS='ORBITING'
            if fault=='pe':ship.PERIAPSIS=-1;ship.STATUS='ORBITING'
            if fault=='ecc':ship.ORBIT.ECCENTRICITY=math.nan;ship.STATUS='ORBITING'
            if fault=='fuel':ship.DELTAV.VACUUM=299
            if fault=='stage-fuel':env['STAGE'].DELTAV.VACUUM=1;ship.STATUS='LANDED'
            if fault=='twr':ship.AVAILABLETHRUST=.1;ship.STATUS='LANDED'
            if fault=='mass':ship.MASS=0;ship.STATUS='LANDED'
            if fault=='reserve':env['EXCURSION_RESERVE_DV']=math.nan
            if fault=='partial-site':opts=fleet.native(dict(lat=1))
            if fault=='nan-site':opts=fleet.native(dict(lat=math.nan,lng=1))
            if fault=='unknown':opts['warp']=fleet.native(1)
            if fault=='string':opts['ap']=fleet.native('659734')
            if fault in ('ap','pe-target','inc','lan','aop','after'):
                key={'pe-target':'pe'}.get(fault,fault)
                opts[key]=fleet.native({'ap':3e6,'pe':9999,'inc':181,'lan':360,'aop':math.nan,'after':'XING'}[key])
            if fault=='profile':world['loaded']=False
            before=state.copy();env['opts']=opts
            entry.call((ROOT/('cmd/visit.ks' if visit else 'cmd/orbit.ks')).read_text(),'_cmdVisit' if visit else '_cmdOrbit',env)
            assert state==before and not updates and not events,(surface,fault,state,updates,events)
    for fault in ('missing','body','mission','vehicle','node','interrupted','falling','cutoff'):
        env,ship,state,events,_,_=fixture()
        assert env['excursionSelect'](fleet.Map(),False)
        if fault=='missing':state['excursion']=fleet.Map()
        if fault=='body':ship.BODY.NAME='Mun'
        if fault=='mission':state['mission_id']='another'
        if fault=='vehicle':state['vehicle']='RO9'
        if fault=='node':env['HASNODE']=True
        if fault=='interrupted':state['burn_started']='true'
        if fault=='falling':ship.STATUS='SUB_ORBITAL'
        if fault=='cutoff':env['thrustCutoffOk']=lambda:False
        before=state.copy();env['phaseExcursionReady']()
        assert state==before and 'advance' not in events
    for path in ('cmd/orbit.ks','cmd/visit.ks'):
        assert not command_entrypoint_errors((ROOT/path).read_text())
    print('PASS: control/node/interruption/orbit/identity/fuel/config/option guards preserve state; no current-stage ascent credit from future stages, no burn or staging in command/checkpoint, and no arbitrary phase dispatch')


def check_per_visit_surface_science():
    env,saved,events=fleet.surface_fixture()
    saved['surface_visit']=fleet.native(1)
    fleet.surface_run(env)
    context1=[e[1] for e in events if isinstance(e,tuple) and e[0]=='sample'][0]
    assert ':visit1' in context1 and saved['surface_science_deadline']==110
    # Same visit, fresh boot: deadline stays elapsed; no repeated dwell/science.
    fresh,_,events2=fleet.surface_fixture(saved);fresh['TIME'].SECONDS=115
    fleet.surface_run(fresh)
    assert saved['surface_science_deadline']==110 and not any(isinstance(e,tuple) and e[0]=='sample' for e in events2)
    saved['surface_visit']=fleet.native(2)
    fresh,_,events3=fleet.surface_fixture(saved);fresh['TIME'].SECONDS=120
    fleet.surface_run(fresh)
    samples=[e for e in events3 if isinstance(e,tuple) and e[0]=='sample']
    assert samples and ':visit2' in samples[0][1] and samples[0][1]!=context1
    assert saved['surface_science_deadline']==130
    assert events3.index(('alarm',130))<events3.index(samples[0])
    assert 'advance' in events3 and not any('launch' in str(e).lower() for e in events3)
    print('PASS: each explicit landing visit gets a distinct science context and KAC dwell before returning to prompt; rebooting the same visit preserves its deadline and samples ledger')


if __name__=='__main__':
    check_profiles_and_scanner_handoff()
    check_surface_relaunch_and_visit_checkpoint()
    check_command_and_checkpoint_guards()
    check_per_visit_surface_science()
