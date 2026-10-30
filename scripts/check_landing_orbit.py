"""Generic landing-orbit preparation; source/Kepler fixtures, not native KSP."""
import copy
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure, mask
from check_deorbit_geometry import Vec
from check_runtime_contracts import KList
from check_surface_return import read_settings, literal
from check_minmus_kolniya import PROFILE
from check_burn_completion import retry_fixture, retry

SOURCE=(ROOT/'lib/landing_orbit.ks').read_text()
ROUTE=(ROOT/'lib/landing_route.ks').read_text()
CONFIG=(ROOT/'lib/landing_config.ks').read_text()
SHAPE=(ROOT/'lib/orbit_shape.ks').read_text()
DEORBIT=(ROOT/'lib/landing_deorbit.ks').read_text()
ks.SOURCES+='\n'+SOURCE+'\n'+CONFIG+'\n'+SHAPE+'\n'+ROUTE


class Seq(KList):
    CONTAINS=list.__contains__


class Lex(dict):
    LENGTH=property(len)
    HASKEY=dict.__contains__
    ADD=dict.__setitem__
    ISTYPE=lambda self,name:name=='Lexicon'
    COPY=property(lambda self:Lex(self))


class Scalar(float):
    # Native kOS scalars support ISTYPE, including a planner's no-node0.
    ISTYPE=lambda self,name:False


def normal(inc,lan):
    inc,lan=map(math.radians,(inc,lan))
    return Vec((math.sin(inc)*math.cos(lan),math.sin(inc)*math.sin(lan),math.cos(inc)))


def fixture(profile=True):
    env=ks.environment()
    read_settings(SHAPE,env,'GLOBAL');read_settings(ROUTE,env,'GLOBAL');read_settings(SOURCE,env,'GLOBAL')
    if profile:read_settings(PROFILE,env)
    env.update(LEXICON=lambda *args:Lex(zip(args[::2],args[1::2])),
               LEX=lambda *args:Lex(zip(args[::2],args[1::2])),LIST=lambda *args:Seq(args),
               SIN=lambda x:math.sin(math.radians(x)),COS=lambda x:math.cos(math.radians(x)),
               ARCSIN=lambda x:math.degrees(math.asin(x)),
               ARCCOS=lambda x:math.degrees(math.acos(x)),VANG=lambda a,b:math.degrees(math.acos(max(-1,min(1,float(a@b)/a.MAG/b.MAG)))),
               CONSTANT=NS(PI=math.pi),ROUND=round,ABORT=False,phaseShouldYield=False,HASNODE=False,
               BURN_STAGE_LIMIT=0,MIN_AOP_TARGET_ECC=.004,NEAR_CIRC_ECC=.01,
               HOMECONNECTION=NS(ISCONNECTED=True),configLiteral=literal)
    env['xferSeq']=Seq(['SHAPE','SCIENCE_OPS','LAND_PREP','LAND_DEORBIT','LAND_ASSIST','SURFACE_RETURN_SETUP'])
    env['launchSeq']=env['xferSeq']
    orbit=NS(PERIAPSIS=9300,APOAPSIS=397272,INCLINATION=63.4,LAN=79.2,ARGUMENTOFPERIAPSIS=90,
             HASNEXTPATCH=False)
    ship=NS(STATUS='ORBITING',PERIAPSIS=9300,APOAPSIS=397272,ALTITUDE=100000,MASS=1.287,
            BODY=NS(NAME='Minmus',RADIUS=60000,MU=1.7658e9,ROTATIONPERIOD=40400,ATM=NS(EXISTS=False)),
            ORBIT=orbit,THRUST=0,AVAILABLETHRUST=55,DELTAV=NS(VACUUM=2093.9),
            CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
    env.update(SHIP=ship,ETA=NS(PERIAPSIS=1000,APOAPSIS=11000),STAGE=NS(NUMBER=3,DELTAV=NS(VACUUM=313)))
    def refresh():
        br=ship.BODY.RADIUS
        orbit.SEMIMAJORAXIS=(ship.APOAPSIS+ship.PERIAPSIS+2*br)/2
        orbit.ECCENTRICITY=(ship.APOAPSIS-ship.PERIAPSIS)/(2*orbit.SEMIMAJORAXIS)
        orbit.PERIOD=2*math.pi*math.sqrt(orbit.SEMIMAJORAXIS**3/ship.BODY.MU)
        orbit.APOAPSIS=ship.APOAPSIS;orbit.PERIAPSIS=ship.PERIAPSIS
    refresh()
    saved=dict(phase='LAND_PREP',mission_id='minmus_kolniya_flats_return',launch_time='2460361',
               shape_budget_spent=97.18,shape_budget_id='Minmus:2460361')
    disk=copy.deepcopy(saved)
    events=[];nodes=[]
    def persist(key,value):
        assert ship.THRUST==0
        if key in saved and saved[key]==value:return False
        saved[key]=value;disk.clear();disk.update(copy.deepcopy(saved));events.append(('state',key))
        return True
    env.update(stateGet=lambda key,default=None:saved.get(key,default),fixture_disk=disk,
               stateGetNum=lambda key,default=0:saved.get(key,default),stateSet=persist,
               stateRemove=lambda key:saved.pop(key,None),fixture_wait=lambda dt:events.append(('wait',dt)),
               yieldToPrompt=lambda:env.update(phaseShouldYield=True),
               vesselLandingPrepareRoles=lambda:True,vesselLandingStageFloor=lambda:2,
               vesselLandingThrust=lambda:ship.AVAILABLETHRUST,vesselLandingReserveAcc=lambda:2.72,
               landingResolveTarget=lambda:Lex(FOUND=False),
               maneuverBurnInterrupted=lambda:saved.get('burn_started')=='true' and saved.get('burn_phase')==saved['phase'],
               nextPhase=lambda seq:saved.update(phase=seq[seq.index(saved['phase'])+1]),
               _shipNormal=lambda:normal(orbit.INCLINATION,orbit.LAN),planeNormalFromIncLan=normal,
               _angDiff=lambda a,b:(a-b+180)%360-180)
    for name in re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',SOURCE+'\n'+ROUTE):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    # Native string coercion and diagnostic presentation are not simulated.
    env['landingRouteLines']=lambda result:Seq()
    def link_wait():
        # Mutations from wait callbacks represent native global controls,
        # which must remain live across loop iterations.
        try:ks.run(ks.parse(function_body(SOURCE,'_landPrepLinkWait')),env)
        except ks.Returned as result:return result.value
    env['_landPrepLinkWait']=link_wait
    env['_landPrepNextCached']=lambda:False
    for name in ('landingOrbitContext','shapeErrors','shapeConverged','_peFloor','_shapeRepairPeriapsis'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    def next_burn(targets):
        result=ks.call('shapeNextBurn',env,targets)
        return result if isinstance(result,Lex) else Scalar(result)
    env['shapeNextBurn']=next_burn
    def apsis(eta,ta,opposite,label,targets):
        # Native NODE/ORBIT substitute: independent vis-viva propagation at
        # the requested apsis. The real shapeNextBurn chooses order/timing.
        burn_alt=ship.PERIAPSIS if ta==0 else ship.APOAPSIS
        radius=ship.BODY.RADIUS+burn_alt;other=ship.BODY.RADIUS+opposite
        old_speed=math.sqrt(ship.BODY.MU*(2/radius-1/orbit.SEMIMAJORAXIS))
        new_speed=math.sqrt(ship.BODY.MU*(2/radius-2/(radius+other)))
        cost=abs(new_speed-old_speed)
        if cost<env['SHAPE_MIN_BURN_DV']:return Scalar(0)
        after=NS(APOAPSIS=max(burn_alt,opposite),PERIAPSIS=min(burn_alt,opposite),
                 INCLINATION=orbit.INCLINATION,LAN=orbit.LAN,HASNEXTPATCH=False)
        after.ECCENTRICITY=(after.APOAPSIS-after.PERIAPSIS)/(2*ship.BODY.RADIUS+after.APOAPSIS+after.PERIAPSIS)
        node=NS(TIME=env['TIME'].SECONDS+eta,ETA=eta,DELTAV=NS(MAG=cost),ORBIT=after)
        env.update(NEXTNODE=node,HASNODE=True);nodes.append(node);events.append(('plan',label,ta,cost))
        return Lex(node=node,label=label)
    def execute():
        node=env['NEXTNODE'];assert env['BURN_STAGE_LIMIT']==2
        events.append(('execute',node.TIME,node.DELTAV.MAG))
        ship.PERIAPSIS=node.ORBIT.PERIAPSIS;ship.APOAPSIS=node.ORBIT.APOAPSIS
        ship.DELTAV.VACUUM-=node.DELTAV.MAG;env['STAGE'].DELTAV.VACUUM-=node.DELTAV.MAG
        env['HASNODE']=False;refresh();return True
    def remove(node):
        assert node is env['NEXTNODE'];env['HASNODE']=False;events.append(('remove',node))
    env.update(_apsisBurn=apsis,executeManeuver=execute,fixture_remove=remove,
               thrustCutoffOk=lambda:events.append(('cutoff',)) or True)
    return env,saved,events,nodes,refresh


def run(env):
    source=function_body(SOURCE,'_landPrepRun').replace('REMOVE nd.','fixture_remove(nd).')
    def body(*args):
        env['targets']=args[0]
        try:ks.run(ks.parse(source),env)
        except ks.Returned as result:return result.value
    env['_landPrepRun']=body
    # SET of native globals is visible to called functions. Execute this
    # owner in the shared fixture environment, as other shaping fixtures do.
    try:ks.run(ks.parse(function_body(SOURCE,'phaseLandPrep')),env)
    except ks.Returned as result:return result.value


def check_kolniya_transition():
    env,saved,events,nodes,refresh=fixture()
    preserve={key:env[key] for key in ('SHAPE_AP','SHAPE_PE','SHAPE_INC','SHAPE_LAN','SHAPE_AOP',
              'SHAPE_ALT_TOL','SHAPE_MIN_PE','SHAPE_MIN_BURN_DV','SHAPE_ANG_TOL','BURN_STAGE_LIMIT',
              'TARGET_LAT','TARGET_LNG','TARGET_LOCK','SURFACE_RETURN_ORBIT','RETURN_PE')}
    old_period=env['SHIP'].ORBIT.PERIOD
    run(env)
    assert saved['phase']=='LAND_DEORBIT' and len(nodes)==1
    assert nodes[0].ORBIT.PERIAPSIS==9300 and nodes[0].ORBIT.APOAPSIS==19300
    assert 45<nodes[0].DELTAV.MAG<55 and env['SHIP'].ORBIT.INCLINATION==63.4
    assert all(env[key]==value for key,value in preserve.items())
    assert saved['shape_budget_spent']==97.18 and saved['land_prep_budget']['SPENT']==nodes[0].DELTAV.MAG
    assert saved['landing_orbit_ready']==env['landingOrbitContext']()
    new_period=env['SHIP'].ORBIT.PERIOD
    assert abs(2*old_period-40400)<10 and new_period<4000
    assert abs(new_period/40400-.5)>.3
    print(f'PASS: actual generic phase/planner selects one Pe burn ({nodes[0].DELTAV.MAG:.2f}m/s) from9.3×397.272km to9.3×19.3km, changes repeating period{old_period:.0f}→{new_period:.0f}s, keeps63.4deg/waypoint/return/strict contract settings and a separate ledger')


def check_generic_goals():
    env,saved,events,nodes,refresh=fixture(False)
    env['SHIP'].PERIAPSIS=200000;env['SHIP'].APOAPSIS=500000;refresh()
    targets=env['landingPrepTargets']()
    assert (targets['PE'],targets['AP'],targets['INC'])==(11000,21000,63.4)
    env['LAND_PREP_DV_CAP']=500;env['LAND_PREP_TOTAL_DV_CAP']=1000;env['LAND_PREP_RESERVE_DV']=100
    env['STAGE'].DELTAV.VACUUM=1500
    run(env)
    assert saved['phase']=='LAND_DEORBIT'
    assert [e[1] for e in events if e[0]=='plan']==['set-pe','set-ap']
    env,saved,events,nodes,refresh=fixture(False)
    env['SHIP'].BODY.ATM=NS(EXISTS=True,HEIGHT=70000)
    env['SHIP'].PERIAPSIS=100000;refresh()
    targets=env['landingPrepTargets']();assert targets['PE']==81000 and targets['AP']==91000
    env['LAND_PREP_PE']=50000;assert not env['landingPrepTargets']()
    env,saved,events,nodes,refresh=fixture()
    env.update(LAND_PREP_INC=90,LAND_PREP_LAN=120)
    targets=env['landingPrepTargets']();assert targets['INC']==90 and targets['LAN']==120
    assert 'planPlaneMatch(tInc, tLan)' in function_body(SHAPE,'shapeNextBurn')
    plane=function_body(SHAPE,'planPlaneMatch')
    assert 'orbitNodeAngleToRelativeAscending' in plane and 'orbitNodeAngleToRelativeDescending' in plane
    assert 'rDN > rAN' in plane # Existing lower-speed intersection choice, not an assumed Ap.
    print('PASS: generic high-Pe orbit lowers Pe before Ap, automatic atmospheric goals respect atmosphere+10km floor, explicit polar/LAN requests use the existing true plane-intersection planner; no default AoP/plane flattening')


def check_groundtrack_coverage():
    # Independent Kepler crossings at the requested latitude, with Minmus
    # rotation. This is a ground-track coverage bound, not a TR landing proof.
    def coverage(ap):
        radius=60000.;pe=9300.;spin=40400.
        semi=(2*radius+pe+ap)/2;ecc=(ap-pe)/(2*semi)
        period=2*math.pi*math.sqrt(semi**3/1.7658e9)
        misses=[]
        for latitude in (-60,-30,0,30,60):
            lat=math.radians(latitude);inc=math.radians(63.4)
            first=math.acos(math.sin(lat)/math.sin(inc));longitudes=[]
            for ta in (first,2*math.pi-first):
                ea=2*math.atan2(math.sqrt(1-ecc)*math.sin(ta/2),math.sqrt(1+ecc)*math.cos(ta/2))
                mean=(ea-ecc*math.sin(ea))%(2*math.pi)
                longitude=math.atan2(math.cos(ta)*math.cos(inc),-math.sin(ta))
                for turn in range(50):
                    ut=(mean/(2*math.pi)+turn)*period
                    if ut<3*spin:longitudes.append(longitude-2*math.pi*ut/spin)
            for target in range(0,360,15):
                misses.append(min(radius*math.acos(max(-1,min(1,math.sin(lat)**2
                    +math.cos(lat)**2*math.cos(lon-math.radians(target))))) for lon in longitudes))
        return period,misses
    env,_,_,_,_=fixture();new=env['landingPrepTargets']()
    before,old_misses=coverage(397272);after,new_misses=coverage(new['AP'])
    assert max(new_misses)<4000 and max(old_misses)>80000
    cfg=read_settings(PROFILE,{})
    assert cfg['TARGET_DEORBIT_SCAN_ORBITS']*after>=3*40400
    assert 'samples >= 4096' in function_body((ROOT/'lib/deorbit_targeting.ks').read_text(),'_targetDeorbitFixedPasses')
    assert 'TARGET_DEORBIT_MAX_EVALUATIONS IS 64.' in (ROOT/'lib/deorbit_targeting.ks').read_text()
    print('PASS: independent rotating Kepler geometry across120 latitude/longitude sites replaces repeating sparse coverage with <4km crossing misses over three rotations; profile surveys48 low-orbit passes under unchanged4096-geometry/64-native bounds')


def check_admission_limits():
    for fault in ('ok','minimum','low-pe','unbound','patch','wrong-plane','no-progress','late','subminimum',
                  'nan','wrong-context','total','reserve','stage','idle','modified-owned-cost'):
        env,saved,events,nodes,refresh=fixture()
        env.update(SHAPE_ALT_TOL=1000,SHAPE_ANG_TOL=.5,SHAPE_MIN_PE=9000,SHAPE_MIN_BURN_DV=.3)
        targets=env['landingPrepTargets']();env['shapeNextBurn'](targets);node=nodes[0]
        ledger=Lex(CONTEXT=env['landingOrbitContext'](),SPENT=0,NODE_UT=-1,NODE_DV=0)
        saved['land_prep_budget']=ledger
        if fault=='low-pe':node.ORBIT.PERIAPSIS=8999
        if fault=='unbound':node.ORBIT.ECCENTRICITY=1
        if fault=='patch':node.ORBIT.HASNEXTPATCH=True
        if fault=='wrong-plane':node.ORBIT.INCLINATION=90
        if fault=='no-progress':node.ORBIT.APOAPSIS=env['SHIP'].APOAPSIS
        if fault=='late':node.ETA=59
        if fault=='minimum':node.DELTAV.MAG=.1
        if fault=='subminimum':node.DELTAV.MAG=.05
        if fault=='nan':node.DELTAV.MAG=math.nan
        if fault=='wrong-context':ledger['CONTEXT']='other-flight'
        if fault=='total':ledger['SPENT']=299
        if fault=='reserve':env['SHIP'].DELTAV.VACUUM=940
        if fault=='stage':env['STAGE'].DELTAV.VACUUM=node.DELTAV.MAG+9
        if fault=='idle':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='modified-owned-cost':
            env['LAND_PREP_TOTAL_DV_CAP']=55
            ledger.update(SPENT=45,NODE_UT=node.TIME,NODE_DV=45);node.DELTAV.MAG=60
        assert bool(env['_landPrepAdmit'](node,targets))==(fault in ('ok','minimum')),fault
    print('PASS: fresh/retained preparation admission enforces progress, plane preservation, hard Pe/patch/corridor, minimum, context, lead, idle controls, separate total budget, current-stage fuel and return reserve; enlarged owned nodes pay their extra cost')


def check_polar_small_trim():
    profile=(ROOT/'missions/RO9/minmus_polar_hops_return.ks').read_text()
    # Independent vis-viva inverse: choose an achieved Pe requiring exactly
    # the reported0.297m/s set-pe trim from a19.3km Ap to9.3km Pe.
    mu=1.7658e9;at=79300.;target=69300.
    target_speed=math.sqrt(mu*(2/at-2/(at+target)))
    achieved_speed=target_speed+.297
    achieved_pe=2/(2/at-achieved_speed**2/mu)-at-60000
    assert achieved_pe-9300>250
    for minimum,expected in ((.3,False),(.1,True)):
        env,saved,events,nodes,refresh=fixture(False)
        read_settings(profile,env)
        assert env['LAND_PREP_MIN_BURN_DV']==.1
        env['LAND_PREP_MIN_BURN_DV']=minimum
        env['xferSeq']=env['launchSeq']=Seq(env['SEQUENCE'])
        saved['mission_id']='minmus_polar_hops_return'
        env['SHIP'].PERIAPSIS=achieved_pe;env['SHIP'].APOAPSIS=19300
        env['SHIP'].ORBIT.INCLINATION=90;env['SHIP'].ORBIT.LAN=298.9
        env['SHIP'].ORBIT.ARGUMENTOFPERIAPSIS=244.9
        refresh()
        prior={k:env[k] for k in ('SHAPE_MIN_BURN_DV','SHAPE_ALT_TOL','SHAPE_MIN_PE','BURN_STAGE_LIMIT')}
        run(env)
        assert len(nodes)==int(expected) and env['phaseShouldYield']==(not expected)
        assert saved['phase']==('LAND_DEORBIT' if expected else 'LAND_PREP')
        assert ('landing_orbit_ready' in saved)==expected
        assert all(env[k]==v for k,v in prior.items())
        if expected:
            assert abs(nodes[0].DELTAV.MAG-.297)<1e-9
            assert abs(env['SHIP'].PERIAPSIS-9300)<1e-6
            assert abs(saved['land_prep_budget']['SPENT']-.297)<1e-9
    print('PASS: native-style0.297m/s polar Pe trim is blocked by0.3 but executes at0.1, meets unchanged250m tolerance, records readiness and advances to LAND_DEORBIT while restoring strict SHAPE/stage policy')


def check_wait_and_cancel():
    env,saved,events,nodes,refresh=fixture();env['HOMECONNECTION'].ISCONNECTED=False
    env['_landPrepNextCached']=lambda:True
    assert env['_landPrepLinkWait']() and not events
    for kac in (True,False):
        env,saved,events,nodes,refresh=fixture();env['HOMECONNECTION'].ISCONNECTED=False
        waits=[0]
        def alarm(*args):events.append(('alarm',args[1]));return 'owned' if kac else ''
        def solar(*args):
            assert events[-1][0]=='alarm';events.append(('solar',args[-1]));return 1
        def wait(body,ut,poll,owned,solar_ref,health,stay):
            assert stay and health and body is env['SHIP'].BODY
            assert owned==('owned' if kac else '')
            waits[0]+=1;env['TIME'].SECONDS=ut
            if waits[0]==3:env['HOMECONNECTION'].ISCONNECTED=True
        env.update(kacEnsureAlarm=alarm,enterSolarCoast=solar,waitUntilOrSOI=wait,
                   DELETEALARM=lambda alarm:events.append(('delete',alarm)))
        assert env['_landPrepLinkWait']() and waits[0]==3
        assert sum(e[0]=='delete' for e in events)==3*int(kac)
        assert saved['phase']=='LAND_PREP' and not env['phaseShouldYield']
    for cancel in ('abort','node','body','impact'):
        env,saved,events,nodes,refresh=fixture();env['HOMECONNECTION'].ISCONNECTED=False
        env.update(kacEnsureAlarm=lambda *_:'owned',enterSolarCoast=lambda *_:1,
                   DELETEALARM=lambda alarm:events.append(('delete',alarm)))
        def wait(*args):
            if cancel=='abort':env['ABORT']=True
            if cancel=='node':env['HASNODE']=True
            if cancel=='body':env['SHIP'].BODY=NS(NAME='Mun',ATM=NS(EXISTS=False))
            if cancel=='impact':env['SHIP'].STATUS='SUB_ORBITAL'
        env['waitUntilOrSOI']=wait
        assert not env['_landPrepLinkWait']() and events==[('delete','owned')]
    print('PASS: missing next-band link stays in a KAC-before-solar clock wait, including without KAC; three wake cycles do not yield/advance, while Abort/new node/body/impact stop cleanly and delete only the owned alarm')


def check_reboot_and_holds():
    env,saved,events,nodes,refresh=fixture();execute=env['executeManeuver']
    env['LAND_PREP_TOTAL_DV_CAP']=55 # A duplicate reservation would reject.
    env['executeManeuver']=lambda:(_ for _ in ()).throw(RuntimeError('reboot'))
    before=env['SHAPE_ALT_TOL']
    try:run(env)
    except RuntimeError:pass
    else:raise AssertionError('missed interruption')
    cost=saved['land_prep_budget']['SPENT'];assert 45<cost<55 and env['HASNODE']
    assert env['fixture_disk']['land_prep_budget']==saved['land_prep_budget']
    saved.clear();saved.update(copy.deepcopy(env['fixture_disk']))
    # A new boot reloads policy globals. Saved context/node remain native.
    env.update(SHAPE_ALT_TOL=before,SHAPE_ANG_TOL=.1,SHAPE_MIN_PE=9000,SHAPE_MIN_BURN_DV=.002,BURN_STAGE_LIMIT=0)
    env['executeManeuver']=execute
    run(env)
    assert len(nodes)==1 and saved['land_prep_budget']['SPENT']==cost and saved['phase']=='LAND_DEORBIT'
    for fault in ('budget','fuel','stage','abort','interrupted','foreign','cutoff'):
        env,saved,events,nodes,refresh=fixture();initial_policy=env['SHAPE_ALT_TOL']
        if fault=='budget':env['LAND_PREP_TOTAL_DV_CAP']=10
        if fault=='fuel':env['SHIP'].DELTAV.VACUUM=930
        if fault=='stage':env['STAGE'].DELTAV.VACUUM=10
        if fault=='abort':env['ABORT']=True
        if fault=='interrupted':saved.update(burn_started='true',burn_phase='LAND_PREP')
        if fault=='foreign':env.update(HASNODE=True,NEXTNODE=NS(TIME=99999))
        if fault=='cutoff':env['thrustCutoffOk']=lambda:False
        run(env)
        assert saved['phase']=='LAND_PREP' and env['phaseShouldYield']
        assert env['SHAPE_ALT_TOL']==initial_policy
        if fault not in ('cutoff',):assert not any(e[0]=='execute' for e in events)
        if fault in ('budget','fuel','stage'):assert not env['HASNODE'] # Only our rejected new node removed.
    env,saved,removed=retry_fixture();saved.update(phase='LAND_PREP',burn_phase='LAND_PREP',land_prep_budget=Lex(SPENT=49))
    assert retry(env) and saved['land_prep_budget']['SPENT']==49 and saved['phase']=='LAND_PREP'
    print('PASS: reboot reuses the unflown preparation node without double charging; budget/fuel/current-stage/Abort/interruption/foreign-node/cutoff failures hold and restore contract policy; explicit shaperetry also preserves LAND_PREP ledger')


def check_inflight_routing_and_dependencies():
    prefix=function_body(DEORBIT,'phaseLandDeorbit').split('IF SHIP:STATUS = "SUB_ORBITAL"',1)[0]
    for kind in ('upgrade','ready','other-mission','node','committed'):
        env,saved,events,nodes,refresh=fixture()
        saved['phase']='LAND_DEORBIT';env['landingApplyMissionConfig']=lambda:True
        if kind=='ready':saved['landing_orbit_ready']=env['landingOrbitContext']()
        if kind=='other-mission':env['launchSeq']=Seq(['LAND_DEORBIT','LAND_ASSIST'])
        if kind=='node':env['HASNODE']=True
        if kind=='committed':saved['deorbit_burn_started']='true'
        try:ks.run(ks.parse(prefix),env)
        except ks.Returned:pass
        assert saved['phase']==('LAND_PREP' if kind=='upgrade' else 'LAND_DEORBIT')
        assert env['phaseShouldYield']==(kind=='node')
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    roots=closure(phases['land_prep'],deps)
    assert {'orbit_shape','maneuver','solar','thrust_cutoff','landing_roles'}<=roots
    assert not {'deorbit_targeting','landing_main','landing_prediction'}&roots
    assert 'landing_orbit' not in closure(phases['shape'],deps)
    assert bands['land_prep']==['land_prep']
    # Actual local-cache inspection resolves dependencies, not merely the
    # next handler's filename, and never loads the heavy landing band here.
    env,_,_,_,_=fixture();cached=set(closure(phases['land_deorbit'],deps))
    env.update(bootLibBandForPhase=lambda name,default:name.lower(),
               bootLibBandRoots=lambda band:Seq(phases[band]),
               missionTypeConditionalRoots=lambda _:Seq(),missionTypeCacheRoots=lambda *_:Seq(),missionExtraLibs=lambda:Seq(),
               missionAppendUnique=lambda dest,src:dest.extend(x for x in src if x not in dest),
               LIBS=Seq(),dependencyLibs=lambda:deps,bootLibArchiveOnly=lambda _:False,
               bootLocalScriptPath=lambda name:'1:/lib/'+name+'.ksm' if name in cached else '')
    def resolve(dest,name,dependencies):
        for item in dependencies.get(name,[]):resolve(dest,item,dependencies)
        if name not in dest:dest.ADD(name)
    env['bootLibAppendResolved']=resolve
    assert ks.call('_landPrepNextCached',env)
    cached.remove('deorbit_burn');assert not ks.call('_landPrepNextCached',env)
    cached.add('deorbit_burn');env['bootLibArchiveOnly']=lambda name:name=='deorbit_burn'
    assert not ks.call('_landPrepNextCached',env)
    assert not re.search(r'(?<!:)\b(?:STAGE|LOCK|UNLOCK|REBOOT)\b(?!:)',mask(SOURCE))
    assert 'executeManeuver()' in SOURCE
    print('PASS: already-inflight LAND_DEORBIT routes into missing preparation, preserves nodes/committed descent and other missions; dedicated band shares maneuver/solar/role safeguards without pulling landing predictor/FSM into memory')


if __name__=='__main__':
    check_kolniya_transition()
    check_generic_goals()
    check_groundtrack_coverage()
    check_admission_limits()
    check_polar_small_trim()
    check_wait_and_cancel()
    check_reboot_and_holds()
    check_inflight_routing_and_dependencies()
