"""Native-node transaction/2D response fixtures; invented drag, not Trajectories."""
import math
from types import SimpleNamespace as NS
import check_entry_landing as entry
from check_codebase import ROOT,function_body
from check_deorbit_geometry import Vec,Geo,dot,cross
from check_runtime_contracts import KList as BaseList

class KList(BaseList):
    def REMOVE(self,index):return self.pop(int(index))

SOURCE=(ROOT/'lib/atmo_deorbit.ks').read_text()
SOURCE=SOURCE.replace('ADD nd.','fixture_add(nd).').replace('REMOVE nd.','fixture_remove(nd).')
SOURCE=SOURCE.replace('atmoLandingNodeReady@','BEFORE_BURN')


def fixture():
    env,ship,state,events=entry.fixture()
    nodes=KList();world=dict(lost=False,offset=0.,slope=0.,light=True)
    body=ship.BODY;body.POSITION=Vec((0,0,0));body.ROTATIONPERIOD=60000
    ship.STATUS='ORBITING';ship.PERIAPSIS=ship.APOAPSIS=70000
    ship.ORBIT=NS(PERIOD=2800,ECCENTRICITY=0,HASNEXTPATCH=False)
    env.update(TARGET_LAT=12.,TARGET_LNG=45.,TARGET_LOCK=1,ALLNODES=nodes,HASNODE=False,
        CONSTANT=NS(PI=math.pi),LANDING_TERRAIN_MAX_SLOPE=5,
        VCRS=cross,ARCCOS=lambda value:math.degrees(math.acos(value)),FLOOR=math.floor,
        MOD=lambda a,b:a%b,
        LIST=lambda *xs:KList(xs),LATLNG=lambda lat,lng:Geo(lat,lng,body),
        stateSet=lambda key,value:state.update({key:value}),stateRemove=lambda key:state.pop(key,None),
        fixture_settle=lambda:None,landingTerrainGrade=lambda *_:world['slope'],
        landingPlanningLight=lambda *_:entry.Map(OK=world['light']),
        landingOrbitContext=lambda:'parked',landingReviewOrbitSafe=lambda:True,
        maneuverBurnInterrupted=lambda:False,bootCacheNextBand=lambda:None,
        launchSeq=KList(['ATMO_DEORBIT','SCIENCE_ENTRY','SURFACE_SCIENCE','DONE']))
    state.update(phase='ATMO_DEORBIT',landing_site_context='parked')
    class Node:
        def __init__(self,epoch,radial,normal,prograde):
            self.TIME,self.RADIALOUT,self.NORMAL,self.PROGRADE=epoch,radial,normal,prograde
            self.ORBIT=NS(PERIAPSIS=5000)
        DELTAV=property(lambda self:NS(MAG=math.hypot(self.PROGRADE,self.NORMAL)))
    def add(node):nodes.append(node);env.update(HASNODE=True,NEXTNODE=node)
    def remove(node):nodes.remove(node);env['HASNODE']=bool(nodes);events.append('remove')
    def wait(dt):env['TIME'].SECONDS+=dt
    class Trajectories:
        AVAILABLE=ISVERTWOTWO=True
        HASIMPACT=property(lambda _:not world['lost'] and bool(nodes))
        TIMETILLIMPACT=property(lambda _:nodes[0].TIME+500-env['TIME'].SECONDS)
        def SETTARGET(self,geo):pass
        @property
        def IMPACTPOS(self):
            node=nodes[0];dt=node.TIME-5025;dn=node.NORMAL-3
            # Coupled two-axis response; actual output is lat/lon on a sphere.
            north=200*dt+1200*dn+world['offset']
            east=700*dt+250*dn+world['offset']
            return Geo(env['TARGET_LAT']+math.degrees(north/body.RADIUS),
                       env['TARGET_LNG']+math.degrees(east/(body.RADIUS*math.cos(math.radians(env['TARGET_LAT'])))),body)
    env.update(NODE=Node,fixture_add=add,fixture_remove=remove,fixture_wait=wait,
        ADDONS=NS(TR=Trajectories()),yieldToPrompt=lambda:events.append('hold'))
    for key,value in __import__('re').findall(r'GLOBAL (\w+) IS ([\d.]+)\.',SOURCE):env[key]=float(value)
    for name in __import__('re').findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:entry.call(SOURCE,name,env,*args)
    env['BEFORE_BURN']=NS(CALL=env['atmoLandingNodeReady'])
    return env,ship,state,events,nodes,world


def context(env,epoch=5000):
    node=env['NODE'](epoch,0,0,-40);env['fixture_add'](node)
    return entry.Map(SHIP=env['SHIP'],BODY=env['SHIP'].BODY,MISSION=env['stateGet']('mission_id'),LAUNCH=1000,
        LAT=env['TARGET_LAT'],LNG=env['TARGET_LNG'],NODE=node,EXPECTED=KList([epoch,0,-40]),
        LOW=4000,HIGH=6000,TRIALS=0,GEOMETRY=0,CANCELLED=False)


def check_coupled_native_fit():
    env,ship,state,events,nodes,world=fixture();ctx=context(env)
    result=env['_atmoFit'](ctx,5000,40)
    assert result['VALID'] and result['DIST']<env['ATMO_DEORBIT_TOLERANCE'],result
    assert abs(result['UT']-5025)<1 and abs(result['NORMAL']-3)<.1,result
    assert ctx['TRIALS']<=64 and env['_atmoAccepted'](result,12,45,nodes[0])
    assert not any(row in events for row in ('burn','advance'))
    for fault in ('slope','light','fuel','plane','pe','lost','target-change'):
        env,ship,state,events,nodes,world=fixture();ctx=context(env,5025)
        node=nodes[0];node.NORMAL=3;ctx['EXPECTED'][1]=3
        result=env['_atmoRead'](ctx)
        if fault=='slope':world['slope']=.2
        if fault=='light':world['light']=False
        if fault=='fuel':env['STAGE'].DELTAV.VACUUM=200
        if fault=='plane':node.NORMAL=11
        if fault=='pe':result['PE']=10000
        if fault=='lost':result['VALID']=False
        if fault=='target-change':env['TARGET_LAT']=30;result=env['_atmoRead'](ctx)
        assert not env['_atmoAccepted'](result,12,45,node),(fault,result)
    print('PASS: actual time/normal Newton solve learns a coupled native lat/lon response within64 probes; target/slope/radio/fuel/Pe/normal failures cannot authorize the fitted node')


def check_geometry_and_takeover():
    env,ship,state,events,nodes,world=fixture()
    for lat,lng,hit_lat,hit_lng in ((0,179.9,0,-179.9),(89.9,45,89.9,-135),(-89.9,-45,-89.8,-44),(12,45,12,45)):
        result=env['atmoLandingOffset'](lat,lng,hit_lat,hit_lng)
        a=Geo(lat,lng,ship.BODY).ALTITUDEPOSITION(0);b=Geo(hit_lat,hit_lng,ship.BODY).ALTITUDEPOSITION(0)
        expected=math.atan2(cross(a,b).MAG,dot(a,b))*ship.BODY.RADIUS
        assert result['VALID'] and abs(result['DIST']-expected)<.01
        assert abs(math.hypot(result['X'],result['Y'])-expected)<.01
    env,ship,state,events,nodes,world=fixture();ctx=context(env)
    def edit(dt):env['TIME'].SECONDS+=dt;nodes[0].NORMAL=77
    env['fixture_wait']=edit
    result=env['_atmoPut'](ctx,5000,0,-40)
    assert not result['VALID'] and ctx['CANCELLED'] and nodes[0].NORMAL==77
    assert not env['_atmoOwns'](ctx) and 'remove' not in events
    print('PASS: spherical target basis handles poles/date-line without a future vacuum velocity; pilot/node takeover cancels without restoring over the changed node')


def check_pass_survey():
    env,ship,state,events,nodes,world=fixture()
    def ground(epoch):
        angle=2*math.pi*epoch/ship.ORBIT.PERIOD
        lat=math.degrees(math.asin(math.sin(angle)))
        lng=(0 if math.cos(angle)>=0 else 180)-360*epoch/ship.BODY.ROTATIONPERIOD
        return Geo(lat,lng,ship.BODY)
    site=ground(10000);env.update(TARGET_LAT=site.LAT,TARGET_LNG=site.LNG,lmGroundGeoAt=ground)
    def distance(a,b,c,d):
        x=Geo(a,b,ship.BODY).ALTITUDEPOSITION(0);y=Geo(c,d,ship.BODY).ALTITUDEPOSITION(0)
        return math.atan2(cross(x,y).MAG,dot(x,y))*ship.BODY.RADIUS
    env['geoDistance']=distance
    ctx=entry.Map(SHIP=ship,BODY=ship.BODY,MISSION=state['mission_id'],LAUNCH=1000,
                  LAT=site.LAT,LNG=site.LNG,GEOMETRY=0)
    passes=env['_atmoPasses'](ctx)
    assert 0<len(passes)<=8 and ctx['GEOMETRY']<=4096
    assert min(p['DIST'] for p in passes)<1500,passes
    print('PASS: rotating polar-orbit ground survey ranks reachable future passes before native nodes, remains under4096 geometry samples and never creates a maneuver')


def check_phase_execution_and_resume():
    for fault in ('ok','radio','stale-target','foreign','retained','flown'):
        env,ship,state,events,nodes,world=fixture()
        # Exercise the real fitting/acceptance callbacks; only the separate,
        # already-tested compact burn executor is represented by a stub.
        env['_atmoPasses']=lambda ctx:KList([entry.Map(UT=5700,DIST=0)])
        def advance(_):state['phase']='SCIENCE_ENTRY';events.append('advance')
        def execute(node,lat,lng,before,allow_stage):
            assert not allow_stage
            assert before.CALL(node,lat,lng)
            events.append('burn');env['fixture_remove'](node)
            ship.PERIAPSIS=5000;ship.STATUS='SUB_ORBITAL';return True
        env.update(nextPhase=advance,executeDeorbitNode=execute)
        if fault=='radio':world['light']=False
        if fault=='stale-target':state['landing_site_context']='old'
        if fault in ('foreign','retained','flown'):
            ctx=context(env,5025);node=nodes[0];node.NORMAL=3;ctx['EXPECTED'][1]=3
            if fault!='foreign':
                state['atmo_deorbit_plan']=entry.Map(mission=state['mission_id'],launch=1000,body='Duna',
                    ut=node.TIME,normal=3,prograde=-40,lat=12.,lng=45.)
            if fault=='flown':
                env['fixture_remove'](node);ship.PERIAPSIS=5000;ship.STATUS='SUB_ORBITAL'
        env['phaseAtmoDeorbit']()
        if fault in ('ok','retained'):assert events.count('burn')==1 and events.count('advance')==1 and not nodes,(fault,events)
        elif fault=='flown':assert 'burn' not in events and events.count('advance')==1
        else:assert 'burn' not in events and 'advance' not in events
        if fault=='foreign':assert nodes and 'remove' not in events
    print('PASS: actual phase creates/validates/executes once, resumes only a bound unflown node, hands a flown entry forward without reburning and preserves foreign nodes or failed radio/target intent')


if __name__=='__main__':
    check_coupled_native_fit()
    check_geometry_and_takeover()
    check_pass_survey()
    check_phase_execution_and_resume()
