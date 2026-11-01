"""Execute the minimum-burn handoff with real phase/retry source; no KSP VM."""
from types import SimpleNamespace as NS
import re

import check_midcourse as mid
import check_landing_guidance as ks
from check_minmus_kolniya import configuration
from check_runtime_contracts import run
from check_codebase import function_body, dependency_tables, closure
from check_surface_return import read_settings
from check_espoir_fleet import profile as fleet_profile
from check_deorbit_geometry import evaluate
import math


def fixture(kac=True,profile='kolniya'):
    env,saved,events,alarms,moon,hit=mid.retry_environment()
    cfg=configuration()
    if profile=='tundra':
        cfg=read_settings((ks.ROOT/'missions/RO9/minmus_tundra_survey_return.ks').read_text(),cfg)
    env.update(cfg)
    env.update(BPLANE_MINIMUM_PE_TOL=1500,
               SHIP=env['SHIP'],bplaneCaptureCost=lambda *_:425)
    env['SHIP'].DELTAV=NS(VACUUM=2324.1)
    env['ADDONS'].KAC.AVAILABLE=kac
    moon.NAME='Minmus'
    hit['entryUt']=3020481.2822777
    hit['patch'].PERIAPSIS=8260.
    hit['patch'].INCLINATION=cfg['CAPTURE_INC']+.11
    hit['patch'].LAN=82.
    env['TIME'].SECONDS=3019581.94
    saved['phase']='REFINE_BPLANE'
    saved['bplane_retry_wait']=mid.Lex(mission=saved['mission_id'],launch=0,
        phase='REFINE_BPLANE',target='Minmus',wakeUt=3019581.28,waiting=False,alarm='')
    for name in ('_bplaneMinimumArrivalOk','_bplaneCurrentCorridorOk',
                 '_bplaneElementPlaneError','_bplaneEnsureSoiAlarm'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    for name,parameters in (('_bplaneCurrentCorridorOk',('targetBody','wantPe','wantInc','wantLan')),
                            ('_bplaneElementPlaneError',('inc','lan','wantInc','wantLan'))):
        source=re.sub(r'PARAMETER [^.]+\.', '',function_body(mid.SOURCE,name))
        env[name]=lambda *args,source=source,parameters=parameters:run(source,
            dict(env,**dict(zip(parameters,args))))
    env['_bplaneWantInc']=lambda:cfg['CAPTURE_INC']
    env['measureArrival']=lambda *_:dict(pe=8260,inc=cfg['CAPTURE_INC']+.11,lan=82)
    env['_bplaneCorridorError']=lambda *_:dict(peErr=-1040,planeErr=.11)
    env['_bplaneCorridorOk']=lambda *_:False
    def soi(target,ut,note):
        events.append(('soi',target.NAME,ut))
        if kac:alarms['SOI Minmus']=(ut,note)
    env['ensureSoiAlarm']=soi
    removed=[]
    def remove(node):
        removed.append(node)
        env['HASNODE']=False
    env['fixture_remove']=remove
    node=NS(DELTAV=NS(MAG=.0715459917139251))
    def solve(*_):
        env['HASNODE']=True
        return node
    env['_bplanePlanFullCorrection']=solve
    env['planBplaneCorrection']=lambda *args:ks.call('planBplaneCorrection',env,*args)
    env['_bplaneCorrectionAboveMinimum']=lambda nd:ks.call('_bplaneCorrectionAboveMinimum',env,nd)
    return env,saved,events,alarms,moon,hit,node,removed


def check_reported_final_checkpoint():
    for profile,kac in (('kolniya',False),('kolniya',True),('tundra',False),('tundra',True)):
        env,saved,events,alarms,moon,hit,node,removed=fixture(kac,profile)
        run(function_body(mid.SOURCE,'phaseRefineBplane'),env)
        assert saved['phase']=='COAST_2HALF' and not env['phaseShouldYield']
        assert removed==[node] and not env['HASNODE']
        assert 'bplane_retry_wait' not in saved
        assert any(row[0]=='soi' and row[2]==hit['entryUt'] for row in events)
        assert ('SOI Minmus' in alarms)==kac
        assert not any(row[0]=='yield' for row in events)
        assert env['MIN_EXEC_DV']==.3 and env['BPLANE_REQUIRE_PLANE']==1
        assert env['SHAPE_ALT_TOL']==100 and env['SHAPE_ANG_TOL']==.1
        assert not env['_bplaneMinimumSkip']['ACCEPTED']
    print('PASS: reported0.0715m/s final-checkpoint correction is removed in Kolniya/Tundra; actual REFINE phase advances once, clears retry state and keeps SOI timing with/without KAC, required plane and strict SHAPE intact')


def check_no_burn_safety():
    for failure in ('abort','interrupted','node','missing','wrong-next-body','parent',
                    'surface','low','high','nan','plane','fuel','expired','at-target'):
        env,_,_,_,moon,hit,_,_=fixture()
        if failure=='abort':env['ABORT']=True
        if failure=='interrupted':env['maneuverBurnInterrupted']=lambda:True
        if failure=='node':env['HASNODE']=True
        if failure=='missing':env['findArrivalPatch']=lambda *_:0
        if failure=='wrong-next-body':env['SHIP'].ORBIT.NEXTPATCH.BODY=NS(NAME='Mun')
        if failure=='parent':env['_bplaneParentClearUntil']=lambda *_:False
        if failure=='surface':hit['patch'].PERIAPSIS=-1
        if failure=='low':hit['patch'].PERIAPSIS=7799
        if failure=='high':hit['patch'].PERIAPSIS=10801
        if failure=='nan':hit['patch'].PERIAPSIS=float('nan')
        if failure=='plane':hit['patch'].INCLINATION+=2
        if failure=='fuel':env['SHIP'].DELTAV.VACUUM=1424
        if failure=='expired':hit['entryUt']=env['TIME'].SECONDS
        if failure=='at-target':env['SHIP'].BODY=moon
        assert not env['_bplaneMinimumArrivalOk'](moon,9300,env['CAPTURE_INC'],-1),failure
    # The looser no-burn corridor is explicit, not a global tolerance increase.
    env,_,_,_,moon,_,_,_=fixture()
    env['BPLANE_MINIMUM_PE_TOL']=-1
    assert not env['_bplaneMinimumArrivalOk'](moon,9300,env['CAPTURE_INC'],-1)
    env['BPLANE_MINIMUM_PE_TOL']=1500
    env['BPLANE_REQUIRE_PLANE']=1
    assert env['_bplaneMinimumArrivalOk'](moon,9300,env['CAPTURE_INC'],-1)
    # Nonrequired-plane missions retain their existing safe-handoff policy.
    env['BPLANE_REQUIRE_PLANE']=0
    assert env['_bplaneMinimumArrivalOk'](moon,9300,0,-1)
    print('PASS: no-burn acceptance rejects unsafe/missing/expired encounters, bad required plane, fuel shortage, abort/interruption and pending nodes; absent opt-in retains original Pe tolerance')


def check_handoff_revalidates():
    env,saved,events,_,moon,hit,node,removed=fixture()
    result=env['planBplaneCorrection'](moon,9300,env['CAPTURE_INC'],-1,100,'',True)
    assert result==0 and env['_bplaneMinimumSkip']['ACCEPTED'] and removed==[node]
    hit['patch'].PERIAPSIS=100
    assert env['_bplaneFinishMinimumSkip'](moon,9300,env['CAPTURE_INC'],-1)
    assert env['phaseShouldYield'] and saved['phase']=='REFINE_BPLANE'
    assert not any(row[0]=='advance' for row in events)
    print('PASS: a changed unburned patch cannot inherit minimum-skip acceptance or advance the mission')


def check_both_phases_and_solver_modes():
    for phase,handler,next_phase in (('BPLANE','phaseBplane','COAST_1HALF'),
                                      ('REFINE_BPLANE','phaseRefineBplane','COAST_2HALF')):
        for mode in (0,1):
            env,saved,events,_,moon,_,node,removed=fixture()
            saved['phase']=phase
            env['BPLANE_PE_ONLY']=mode
            env['BPLANE_REQUIRE_PLANE']=1-mode
            env['_bplaneWantInc']=lambda:-1 if mode else env['CAPTURE_INC']
            env['_bplanePlanPeOnly']=env['_bplanePlanFullCorrection']
            node.DELTAV.MAG=.3 # Equality is still a skip, never a burn.
            run(function_body(mid.SOURCE,handler),env)
            assert saved['phase']==next_phase and not env['phaseShouldYield']
            assert removed==[node] and not env['HASNODE']
            assert len([row for row in events if row[0]=='advance'])==1
    print('PASS: both BPLANE/REFINE handlers and full/Pe-only solver paths consume safe minimum skips exactly once;0.3m/s equality cannot authorize a burn')


def lander_fixture(profile):
    env,saved,events,alarms,moon,hit,node,removed=fixture()
    cfg=fleet_profile(profile);env.update(cfg)
    env.update(xferSeq=cfg['SEQUENCE'],BPLANE_ARRIVAL_MODE='ORBIT',
        _bplaneWantInc=lambda:cfg['CAPTURE_INC'])
    hit['patch'].PERIAPSIS=17400
    hit['patch'].INCLINATION=cfg['CAPTURE_INC']-.38
    env['SHIP'].DELTAV.VACUUM=2352.7
    node.DELTAV.MAG=.1736499968
    return env,saved,events,alarms,moon,hit,node,removed,cfg


def check_reported_lander_upper_miss():
    for name in ('minmus_contract_lander_return','minmus_lander'):
        env,saved,events,alarms,moon,hit,node,removed,cfg=lander_fixture(name)
        assert cfg['CAPTURE_PE']==15000 and cfg['CAPTURE_MIN_PE']==13000 and cfg['CAPTURE_MAX_PE']==20000
        assert cfg['BPLANE_PE_TOL']==2000 and cfg['BPLANE_MINIMUM_PE_TOL']==5000
        assert cfg['BPLANE_REQUIRE_PLANE']==1 and cfg['BPLANE_ANG_TOL']==.5
        run(function_body(mid.SOURCE,'phaseRefineBplane'),env)
        assert saved['phase']=='COAST_2HALF' and not env['phaseShouldYield'] and removed==[node]
        assert any(event[0]=='soi' for event in events) and not env['HASNODE']
        phase=function_body(mid.CAPTURE,'phaseCapture')
        gate=re.search(r'IF (\(CAPTURE_MIN_PE.*?CAPTURE_MAX_PE\)) \{',phase,re.S)[1]
        for pe,reject in ((12999,True),(13000,False),(17400,False),(20000,False),(20001,True)):
            assert evaluate(gate,dict(SHIP=NS(PERIAPSIS=pe),CAPTURE_MIN_PE=cfg['CAPTURE_MIN_PE'],
                CAPTURE_MAX_PE=cfg['CAPTURE_MAX_PE']))==reject
            assert env['capturePeriapsisOk'](pe)==(not reject)
        # Independent impulsive cost: raised Pe is safer terrain clearance;
        # actual native capture still enforces the unchanged reserve.
        mu=1.7658e9;radius=60000;vinf=225.602
        def cost(pe):
            rp=radius+pe;ra=radius+cfg['TARGET_AP']
            return math.sqrt(vinf**2+2*mu/rp)-math.sqrt(mu*(2/rp-2/(rp+ra)))
        assert 0<cost(17400)-cost(15000)<3
        assert cost(17400)+cfg['CAPTURE_RESERVE_DV']<2352.7
    print('PASS: recorded17.4km Pe/.17365m/s final trim advances both Minmus landers into their matching13..20km capture window, retaining15km aim, required plane, SOI alarm,0.3m/s floor and fuel reserves')


def check_capture_corridor_fences_minimum_handoff():
    for pe in (12999,20001,math.nan,math.inf):
        env,_,_,_,moon,hit,_,_,cfg=lander_fixture('minmus_contract_lander_return')
        env['BPLANE_MINIMUM_PE_TOL']=100000 # A wider tolerance cannot waive capture's bounds.
        hit['patch'].PERIAPSIS=pe
        assert not env['_bplaneMinimumArrivalOk'](moon,15000,cfg['CAPTURE_INC'],-1)
    env,_,_,_,moon,hit,_,_,cfg=lander_fixture('minmus_contract_lander_return')
    env['BPLANE_ARRIVAL_MODE']='FLYBY';hit['patch'].PERIAPSIS=12999
    assert env['_bplaneMinimumArrivalOk'](moon,15000,cfg['CAPTURE_INC'],-1)
    print('PASS: orbital no-burn handoff cannot cross either configured capture boundary even with a widened tolerance; flyby goals keep their own arrival policy')


def check_capture_config_loading():
    deps,phases,_=dependency_tables((ks.ROOT/'lib/dependencies.ks').read_text())
    for phase in ('bplane','refine_bplane','capture'):
        assert 'capture_config' in closure(phases[phase],deps)
    for phase in ('bplane','refine_bplane'):
        assert 'capture' not in closure(phases[phase],deps)
    print('PASS: both B-plane phases and capture load shared corridor defaults; no capture controller is added to B-plane bands')


if __name__=='__main__':
    check_reported_final_checkpoint()
    check_no_burn_safety()
    check_handoff_revalidates()
    check_both_phases_and_solver_modes()
    check_reported_lander_upper_miss()
    check_capture_corridor_fences_minimum_handoff()
    check_capture_config_loading()
