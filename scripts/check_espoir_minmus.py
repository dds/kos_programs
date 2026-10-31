"""Moon excursion/contract-return handoffs; source fixtures, no native flight VM."""
import math
import re
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


def check_contract_two_sites_return():
    import check_surface_return as home
    cfg=fleet.profile('minmus_contract_lander_return')
    assert [cfg['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[1041045,465764,21.6,255.5,157.3]
    assert cfg['PARKING_ALT']==85000 and cfg['LAUNCH_PLANE_MODE']=='BODY_ORBIT'
    assert cfg['CAPTURE_PE']==cfg['TARGET_PE']==15000 and cfg['TARGET_AP']==1041045
    assert cfg['CAPTURE_INC']==21.6 and cfg['CAPTURE_LAN']==cfg['CAPTURE_AOP']==-1
    assert cfg['CAPTURE_MIN_PE']<=cfg['CAPTURE_PE']<=cfg['CAPTURE_MAX_PE']
    assert cfg['SCIENCE_OPS_HOLD']==1 and cfg['SCIENCE_OPS_RUN_ALL']==0
    seq=cfg['SEQUENCE']
    assert seq[seq.index('SHAPE'):]==['SHAPE','SCIENCE_OPS','LAND_PREP','LANDING_REVIEW',
        'LAND_DEORBIT','LAND_ASSIST','SURFACE_SCIENCE','SURFACE_REVIEW','SURFACE_RETURN_SETUP']
    assert cfg['LAND_PREP_AP']==cfg['LAND_PREP_PE']==15000 and cfg['LAND_PREP_INC']==90 and cfg['LAND_PREP_LAN']==-1
    assert cfg['TARGET_LOCK']==cfg['LANDING_AUTO_TARGET']==0 and cfg['SCIENCE_SURFACE_DWELL']==600
    # Native planner chooses plane before lowering this high contract orbit.
    import check_landing_orbit as prep
    env,saved,events,nodes,refresh=prep.fixture(False);env.update(cfg)
    ship=env['SHIP'];ship.PERIAPSIS=465764;ship.APOAPSIS=1041045
    ship.ORBIT.INCLINATION=21.6;ship.ORBIT.LAN=255.5;refresh()
    targets=env['landingPrepTargets']()
    assert targets['LAN']==255.5 and targets['INC']==90
    planned=[]
    env['shapeErrors']=lambda _:prep.Lex(PLANE=68.4,AP=1026045,PE=450764)
    env['_shapeNodeAboveMinimum']=lambda *_:True
    # First plane call is the actual planner's first attempted correction.
    # Stop there to avoid replacing native plane propagation with a fake burn.
    class FirstPlane(Exception):pass
    def plane(inc,lan):planned.append((inc,lan));raise FirstPlane
    env['planPlaneMatch']=plane
    try:prep.ks.call('shapeNextBurn',env,targets)
    except FirstPlane:pass
    assert planned==[(90,255.5)]
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert bands['surface_review']==['surface_review']
    assert closure(phases['surface_review'],deps)=={'surface_review','thrust_cutoff'}
    for phase in seq:assert phase.lower() in phases
    # Two successive command/reboot visits preserve the return tail, settings
    # and spending. They do not launch, stage or burn in the command itself.
    for visit in (1,2):
        env,ship,state,events,updates,_=fixture(True,'minmus_contract_lander_return')
        env['EXCURSION_RESERVE_DV']=cfg['EXCURSION_RESERVE_DV']
        state.update(phase='SURFACE_REVIEW',surface_visit=visit-1)
        assert env['excursionSelect'](fleet.native(dict(lat=-10*visit,lng=20*visit)),True)
        assert updates['SEQUENCE'][-3:]==['SURFACE_SCIENCE','SURFACE_REVIEW','SURFACE_RETURN_SETUP']
        assert state['shape_budget_spent']==70 and not events
        fresh=read_settings('\n'.join('SET '+key+' TO '+str(fleet.literal(value))+'.' for key,value in updates.items()),dict(cfg))
        for key in ('RETURN_PE','RETURN_PE_MIN','RETURN_ARM_CHUTES','AEROBRAKE_AP_BURN','AEROBRAKE_AP_RESERVE_DV','COAST_AUTO_WARP'):
            assert fresh[key]==cfg[key]
    for after in ('review','scan'):
        env,_,_,events,updates,_=fixture(True,'minmus_contract_lander_return')
        assert env['excursionSelect'](fleet.native(dict(after=after)),False)
        assert updates['SEQUENCE'][-1]=='RETURN_SETUP' and not events
    # Execute both real return serializers with the real coast policy writer.
    writer=function_body(home.SETUP,'_writeCoastAutomation')
    rows=re.findall(r'LOG (.*?) TO profilePath\.',writer)
    def coast(values):return '\n'.join(home.expression(row,values) for row in rows)
    initial=home.defaults()|read_settings((ROOT/'lib/aerobrake_config.ks').read_text(),{},'GLOBAL')
    read_settings((ROOT/'lib/phases.ks').read_text().split('GLOBAL FUNCTION')[0],initial,'GLOBAL')
    initial.update(cfg)
    initial.update(BODY_NAME='MINMUS',LAUNCH_AZIMUTH=90,COAST_HEALTH_CHECK=1,SOLAR_REORIENT_PERIOD=21600)
    surface=read_settings(home.emit_profile('phaseSurfaceReturnSetup',initial)+'\n'+coast(initial),home.defaults())
    surface['targetPe']=surface['RETURN_PE']
    returned=read_settings(home.emit_profile('phaseReturnSetup',surface)+'\n'+coast(surface),{})
    assert surface['SEQUENCE']==['PRELAUNCH','LAUNCH','PARK','RETURN_SETUP']
    assert surface['PARKING_ALT']==15000 and surface['LAUNCH_INCLINATION']==0
    assert returned['SEQUENCE']==['ESCAPE','COAST','MCC','AEROBRAKE','DESCENT','DONE']
    assert returned['AEROBRAKE_PE']==returned['MCC_AEROBRAKE_SAFE_PE_MIN']==52000
    assert returned['AEROBRAKE_AP_BURN']==1 and returned['AEROBRAKE_AP_RESERVE_DV']==10 and returned['COAST_AUTO_WARP']==0
    assert returned['AEROBRAKE_ARM_CHUTES']==1 and returned['DESCENT_DECOUPLER_TAG']=='none'
    print('PASS: low-Pe capture/strict contract precede high-orbit polar change and15km preparation; both later site visits retain return intent/fuel ledgers; two fresh return boots keep52km entry, chutes, excess-fuel assistance/10m/s and no autowarp')


def check_surface_review_stop():
    source=(ROOT/'lib/surface_review.ks').read_text()
    source=source.replace('UNLOCK STEERING.','fixture_unlock().').replace('SAS OFF.','SET SAS TO FALSE.').replace('BRAKES ON.','fixture_brakes().')
    source=re.sub(r'\bPRINT (.*?)\.(?=\s*(?:\n|$))',r'fixture_print(\1).',source,flags=re.S)
    for fault in ('ok','node','abort','moving','wrong-body','thrust','pilot','pending','burn','deorbit','cutoff'):
        env,ship,state,events,_,_=fixture(True,'minmus_contract_lander_return')
        printed=[];env.update(CHAR=lambda n:chr(n),fixture_print=printed.append,fixture_brakes=lambda:events.append('brakes'))
        if fault=='node':env['HASNODE']=True
        if fault=='abort':env['ABORT']=True
        if fault=='moving':ship.VELOCITY.SURFACE.MAG=1
        if fault=='wrong-body':env['getTarget']=lambda:'Mun'
        if fault=='thrust':ship.THRUST=1
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault in ('pending','burn','deorbit'):state[{'pending':'burn_pending','burn':'burn_started','deorbit':'deorbit_burn_started'}[fault]]='true'
        if fault=='cutoff':env['thrustCutoffOk']=lambda:False
        entry.call(source,'phaseSurfaceReview',env)
        assert events[-1]=='hold' and 'advance' not in events
        assert ('brakes' in events)==(fault=='ok')
        if fault=='ok':
            assert any('RUNPATH("0:/cmd/visit.ks")' in row for row in printed)
            assert any('RUNPATH("0:/cmd/setphase.ks","SURFACE_RETURN_SETUP")' in row for row in printed)
    print('PASS: surface review brakes and prints runnable visit/return commands then yields; unsafe context/interruption/cutoff cannot progress or relaunch, no invented KAC deadline')


def check_mun_contract_survey_return():
    import check_surface_return as home
    import check_landing_orbit as prep
    cfg=fleet.profile('mun_contract_survey_return')
    assert [cfg['SHAPE_'+k] for k in ('AP','PE','INC','LAN','AOP')]==[1737680,1543150,180,-1,-1]
    assert cfg['TARGET_']=='MUN' and cfg['MISSION_TYPE']=='kerbin_moon'
    assert cfg['PARKING_ALT']==85000 and cfg['LAUNCH_PLANE_MODE']=='BODY_ORBIT'
    assert cfg['CAPTURE_PE']==cfg['TARGET_PE']==15000 and cfg['TARGET_AP']==1737680
    assert cfg['CAPTURE_MIN_PE']==13000 and cfg['CAPTURE_MAX_PE']==17000
    assert cfg['CAPTURE_INC']==180 and cfg['CAPTURE_LAN']==cfg['CAPTURE_AOP']==-1
    assert cfg['BPLANE_REQUIRE_PLANE']==0 and cfg['CAPTURE_RESERVE_DV']==1200
    assert cfg['SEQUENCE'][-4:]==['CAPTURE','SHAPE','SCIENCE_OPS','RETURN_SETUP']
    assert cfg['SCIENCE_OPS_HOLD']==1 and cfg['SCIENCE_OPS_RUN_ALL']==0
    assert cfg['SCANSAT_TARGET_COVERAGE']==95 and cfg['SCANSAT_DECOUPLER_TAG']==''
    assert cfg['SCANSAT_DISPOSE_CARRIER']==cfg['SCANSAT_AUTO_DEORBIT']==cfg['SCANSAT_STAGE_AFTER_RELEASE']==0
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for phase in cfg['SEQUENCE']:assert phase.lower() in phases and closure(phases[phase.lower()],deps)
    # Execute the actual operator command from the achieved retrograde orbit.
    env,ship,state,events,updates,_=fixture(profile='mun_contract_survey_return')
    ship.BODY=NS(NAME=fleet.Text('Mun'),RADIUS=200000,MU=6.5138398e10,SOIRADIUS=2429559,ATM=NS(EXISTS=False))
    ship.PERIAPSIS=1543150;ship.APOAPSIS=1737680;ship.ORBIT.INCLINATION=180
    state.update(phase='SCIENCE_OPS',shape_budget_id='Mun:1000')
    env['EXCURSION_RESERVE_DV']=cfg['EXCURSION_RESERVE_DV']
    env['opts']=fleet.native(dict(after='scan'))
    entry.call((ROOT/'cmd/orbit.ks').read_text(),'_cmdOrbit',env)
    assert updates['SEQUENCE']==['EXCURSION_READY','SHAPE','SCANSAT_OPS','RETURN_SETUP']
    assert [updates['SHAPE_'+k] for k in ('AP','PE','INC','LAN','AOP')]==[70000,70000,90,-1,-1]
    assert not events and state['phase']=='EXCURSION_READY'
    assert state['shape_budget_spent']==70 and state['shape_budget_id']=='Mun:1000'
    fresh=read_settings('\n'.join('SET '+k+' TO '+str(fleet.literal(v))+'.' for k,v in updates.items()),dict(cfg))
    for key in ('MISSION_ID','SHAPE_DV_CAP','SHAPE_TOTAL_DV_CAP','SHAPE_RESERVE_DV','RETURN_PE','RETURN_PE_MIN','AEROBRAKE_AP_BURN','AEROBRAKE_AP_RESERVE_DV'):
        assert fresh[key]==cfg[key]
    env['phaseExcursionReady']()
    assert events==['cutoff','advance']
    assert state['launch_time']==1000 and state['mission_id']==cfg['MISSION_ID']
    # Real SHAPE priority performs the90deg change before lowering apsides.
    penv,_,_,_,refresh=prep.fixture(False);penv.update(fresh)
    penv['SHIP'].BODY=ship.BODY
    penv['SHIP'].PERIAPSIS=1543150;penv['SHIP'].APOAPSIS=1737680
    penv['SHIP'].ORBIT.INCLINATION=180;penv['SHIP'].ORBIT.LAN=33;refresh()
    chosen=[]
    class FirstPlane(Exception):pass
    def plane(inc,lan):chosen.append((inc,lan));raise FirstPlane
    penv['planPlaneMatch']=plane
    targets=prep.ks.call('shapeTargetsWithPrefix',penv,'SHAPE_')
    try:prep.ks.call('shapeNextBurn',penv,targets)
    except FirstPlane:pass
    assert chosen==[(90,33)]
    # The real return writer must clear the old180deg capture intent and
    # retain the entry corridor/assist policy after the selected mapping leg.
    initial=home.defaults()|read_settings((ROOT/'lib/aerobrake_config.ks').read_text(),{},'GLOBAL')
    read_settings((ROOT/'lib/phases.ks').read_text().split('GLOBAL FUNCTION')[0],initial,'GLOBAL')
    initial.update(fresh);initial.update(BODY_NAME='MUN',targetPe=cfg['RETURN_PE'])
    rows=re.findall(r'LOG (.*?) TO profilePath\.',function_body(home.SETUP,'_writeCoastAutomation'))
    returned=read_settings(home.emit_profile('phaseReturnSetup',initial)+'\n'+'\n'.join(home.expression(row,initial) for row in rows),{})
    assert returned['TARGET_']=='KERBIN' and returned['CAPTURE_INC']==-1
    assert returned['SEQUENCE']==cfg['RETURN_SEQUENCE'] and returned['AEROBRAKE_PE']==52000
    assert returned['MCC_AEROBRAKE_SAFE_PE_MIN']==52000 and returned['MCC_AEROBRAKE_SAFE_PE_MAX']==53000
    assert returned['AEROBRAKE_AP_BURN']==1 and returned['AEROBRAKE_AP_RESERVE_DV']==10
    assert returned['COAST_AUTO_WARP']==0 and returned['DESCENT_DECOUPLER_TAG']=='none' and returned['AEROBRAKE_ARM_CHUTES']==1
    print('PASS: Mun low-Pe capture/retrograde contract review -> real70km polar-map command/plane-first planner preserves identity, budgets and orbital return; fresh home boot clears180deg intent and keeps52km assisted entry/10m/s/chutes/no-autowarp')


if __name__=='__main__':
    check_profiles_and_scanner_handoff()
    check_surface_relaunch_and_visit_checkpoint()
    check_command_and_checkpoint_guards()
    check_per_visit_surface_science()
    check_contract_two_sites_return()
    check_surface_review_stop()
    check_mun_contract_survey_return()
