"""Rendezvous source + independent conics; not native docking/attitude proof."""
import math
import re
from types import SimpleNamespace as NS
from check_codebase import ROOT, function_body, closure, dependency_tables, command_entrypoint_errors
from check_survey_orbit import source_call, Orbit, Node as BaseNode, unit, cross
from check_deorbit_geometry import Vec, dot
from check_espoir_fleet import Items, Text, Map, native
import check_landing_guidance as ks

G=((ROOT/'lib/rendezvous_geometry.ks').read_text()+(ROOT/'lib/docking_geometry.ks').read_text()).replace('LIST TARGETS IN candidates.', 'LOCAL candidates IS fixture_targets().')
P=(ROOT/'lib/rdv_plan.ks').read_text()
M=(ROOT/'lib/maneuver_rendezvous.ks').read_text().replace('SAS OFF.','SET SAS TO FALSE.').replace('SAS ON.','SET SAS TO TRUE.')
L=(ROOT/'lib/lambert.ks').read_text()
H=(ROOT/'lib/hohmann_transfer.ks').read_text().replace(
    'FROM { LOCAL i IS 0. } UNTIL i >= 15 STEP { SET i TO i + 1. } DO {',
    'FOR i IN fixture_indices(15) {')

class V(Vec):
    X=property(lambda s:float(s[0]));Y=property(lambda s:float(s[1]));Z=property(lambda s:float(s[2]))

class Record(Map):
    def __setitem__(self,key,value):dict.__setitem__(self,str(key),value)

class KItems(Items):
    def INSERT(self,i,item): self.insert(int(i),item)
    def REMOVE(self,i): self.pop(int(i))

class Vessel:
    def ISTYPE(self,kind): return kind=='Vessel'
    POSITION=property(lambda s: V(s.ORBIT.state(s.env['TIME'].SECONDS)[0]))
    VELOCITY=property(lambda s:NS(ORBIT=V(s.ORBIT.state(s.env['TIME'].SECONDS)[1])))
    BODY=property(lambda s:s.ORBIT.BODY)
    THRUST=0;ISDEAD=False;LOADED=True;UNPACKED=True
    STAGENUM=1;AVAILABLETHRUST=2;MASS=1
    CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    DELTAV=NS(VACUUM=2000)

class Node(BaseNode):
    @property
    def DELTAV(self):
        pos,vel=self.env['SHIP'].ORBIT.state(self.TIME)
        pro=V(unit(vel));normal=V(unit(cross(pos,vel)))
        # Fixture deliberately reverses the normal axis: native basis
        # extraction must handle either convention without guessing signs.
        return V(cross(pro,normal))*self.RADIALOUT-normal*self.NORMAL+pro*self.PROGRADE
    @property
    def ORBIT(self):
        pos,vel=self.env['SHIP'].ORBIT.state(self.TIME)
        return Orbit(self.env['SHIP'].BODY,pos,V(vel)+self.DELTAV,self.TIME)


def fixture():
    bdy=NS(MU=3.5316e12,RADIUS=600000,ATM=NS(EXISTS=True,HEIGHT=70000))
    radius=800000;speed=math.sqrt(bdy.MU/radius)
    env=dict(TIME=NS(SECONDS=1000.),KUNIVERSE=NS(REALTIME=0.,TIMEWARP=NS(ISSETTLED=True)),
        ABORT=False,WARP=0,HASNODE=False,HASTARGET=False,ALLNODES=KItems(),NEXTNODE=0,
        RDV_MAX_CA=5000,RDV_MAX_RADIUS_ERR=2000,STAGE=NS(DELTAV=NS(VACUUM=2000)))
    env.update(ks.EVAL_GLOBALS)
    saved={};env.update(stateGet=saved.get,stateSet=saved.__setitem__,stateRemove=lambda key:saved.pop(str(key),None))
    for name,phase in [('SHIP',0),('other',.3)]:
        ves=Vessel();ves.NAME=Text(name);ves.env=env
        ves.ORBIT=Orbit(bdy,(radius*math.cos(phase),0,radius*math.sin(phase)),
                        (-speed*math.sin(phase),0,speed*math.cos(phase)),1000.)
        env[name]=ves
    env['KUNIVERSE'].ACTIVEVESSEL=env['SHIP'];env['craftRef']=env['SHIP']
    env.update(CONSTANT=NS(PI=math.pi,DEGTORAD=math.pi/180,RADTODEG=180/math.pi),
        LEX=lambda *xs:Record((str(k),v) for k,v in zip(xs[::2],xs[1::2])),LEXICON=lambda *xs:Record((str(k),v) for k,v in zip(xs[::2],xs[1::2])),
        LIST=lambda *xs:KItems(xs),RANGE=lambda a,b:range(int(a),int(b)),
        V=lambda *xs:V(xs),VCRS=lambda a,b:V(cross(a,b)),VDOT=dot,
        VANG=lambda a,b:math.degrees(math.acos(max(-1,min(1,dot(a,b)/(a.MAG*b.MAG))))),
        SQRT=math.sqrt,LN=math.log,ARCCOS=lambda a:math.degrees(math.acos(a)),ROUND=round,
        fixture_text=Text,fixture_indices=lambda n:range(n),fixture_targets=lambda:KItems([env['other']]),
        fixture_wait=lambda dt:None,fixture_lock=lambda _:None,PRINT=lambda *_:None)
    def add(nd):
        assert not env['HASNODE'];env.update(HASNODE=True,NEXTNODE=nd,ALLNODES=KItems([nd]))
    def remove(nd):
        assert env['NEXTNODE'] is nd
        env.update(HASNODE=False,NEXTNODE=0,ALLNODES=KItems());nd.alive=False
    env.update(fixture_add=add,fixture_remove=remove,NODE=lambda *xs:Node(env,*xs))
    def positions(ves,ut):
        # Deliberately moving parent: each velocity sample must subtract
        # the parent's position at THAT epoch, rather than at current UT.
        parent=V((ut*ut*.02,ut*30,ut*10))
        if ves is bdy:return parent
        orb=ves.ORBIT
        if ves is env['SHIP'] and env['HASNODE'] and ut>env['NEXTNODE'].TIME:
            orb=env['NEXTNODE'].ORBIT
        return parent+V(orb.state(ut)[0])
    env['POSITIONAT']=positions
    for source in (G,P,M,L,H):
        for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',source):
            env[name]=lambda *args,name=name,source=source:source_call(source,name,env,*args)
    return env,saved


def check_geometry_and_node_ownership():
    env,saved=fixture();ship=env['SHIP'];other=env['other']
    expected=V(ship.ORBIT.state(1800)[1]);vel=env['rendezvousVelocity'](ship,1800)
    assert (vel-expected).MAG<.001
    for dv in (V((5,7,-11)),V((-8,-2,3))):
        nd=env['rendezvousNode'](1800,dv,other)
        assert nd and (nd.DELTAV-dv).MAG<1e-8
        stamp=env['rendezvousStamp'](nd)
        nd.NORMAL+=.001
        assert not env['rendezvousRelease'](ship,nd,stamp) and env['HASNODE']
        nd.NORMAL-=.001
        assert env['rendezvousRelease'](ship,nd,stamp) and not env['HASNODE']
    assert env['rendezvousTarget']('other') is other
    env['fixture_targets']=lambda:KItems([other,other])
    assert env['rendezvousTarget']('other')==0
    assert env['rendezvousTarget']('unknown')==0
    for fault in ('abort','warp','active','pending','started','approach','nextpatch','atmosphere','raw','nan-thrust'):
        env,saved=fixture()
        if fault=='abort':env['ABORT']=True
        if fault=='warp':env['WARP']=1
        if fault=='active':env['KUNIVERSE'].ACTIVEVESSEL=env['other']
        if fault in ('pending','started'):saved['burn_'+fault]='true'
        if fault=='approach':saved['rendezvous_active']=True
        if fault=='nextpatch':env['other'].ORBIT.HASNEXTPATCH=True
        if fault=='atmosphere':env['other'].ORBIT.SEMIMAJORAXIS=600100
        if fault=='raw':env['SHIP'].CONTROL=NS(MAINTHROTTLE=.1,PILOTMAINTHROTTLE=0)
        if fault=='nan-thrust':env['SHIP'].THRUST=math.nan
        assert not env['rendezvousContext'](env['SHIP'],env['other']),fault
    print('PASS: moving-parent derivative, signed native node axes, edit-safe cleanup and10 context refusals')


def check_budgets_and_native_intercept():
    env,_=fixture()
    assert env['rendezvousAffordable'](100,150,500,100)
    assert not env['rendezvousAffordable'](100,500,500,100)
    # Opposite velocity at the same point is not an affordable rendezvous.
    circular=math.sqrt(env['SHIP'].BODY.MU/800000)
    assert not env['rendezvousAffordable'](50,2*circular,2000,100)
    for fault in ('stage','ship','nan','engine'):
        e,_=fixture()
        if fault=='stage':e['STAGE'].DELTAV.VACUUM=99
        if fault=='ship':e['SHIP'].DELTAV=NS(VACUUM=250)
        if fault=='nan':assert not e['rendezvousAffordable'](100,math.nan,500,100);continue
        if fault=='engine':e['SHIP'].AVAILABLETHRUST=0
        assert not e['rendezvousAffordable'](100,150,500,100)
    result=env['rendezvousSearch'](env['other'],500,100)
    assert result['OK'],result
    nd=result['NODE'];ca=result['CAUT']
    assert 100<=result['CA']<=5000 and result['BRAKE']+nd.DELTAV.MAG+10<=500
    assert nd.ORBIT.PERIAPSIS>=80000
    # Independent propagation checks the accepted node's actual separation.
    p1=V(nd.ORBIT.state(ca)[0]);p2=V(env['other'].ORBIT.state(ca)[0])
    assert abs((p1-p2).MAG-result['CA'])<.001
    print('PASS: real Lambert -> signed native-node adapter -> independent Kepler encounter, both burns budgeted; opposite-direction unaffordable')


def check_endpoints():
    env,_=fixture();ves=env['SHIP'];peer=env['other']
    class Port:
        NODEPOSITION=V((1,2,3));PORTFACING=NS(FOREVECTOR=V((0,1,0)))
        NODETYPE='size1';HASPARTNER=False
        def ISTYPE(self,kind):return kind=='DockingPort'
    port=Port();ves.PARTSTAGGED=lambda tag:KItems([port])
    end=env['rendezvousEndpoint'](ves)
    assert end['KIND']=='PORT' and (end['POINT']-port.NODEPOSITION).MAG==0
    ves.PARTSTAGGED=lambda tag:KItems([port,Port()])
    assert env['rendezvousEndpoint'](ves)['REASON']=='ambiguous-port-tag'
    bad=NS(ISTYPE=lambda kind:False);ves.PARTSTAGGED=lambda tag:KItems([bad])
    assert env['rendezvousEndpoint'](ves)['REASON']=='tag-is-not-a-port'
    ves.PARTSTAGGED=lambda tag:KItems();ves.FACING=NS(FOREVECTOR=V((0,1,0)))
    ves.BOUNDS=NS(FURTHESTCORNER=lambda axis:ves.POSITION+V((4,6,9)))
    bow=env['rendezvousEndpoint'](ves)
    assert bow['KIND']=='BOW' and (bow['POINT']-ves.POSITION-V((0,6,0))).MAG==0
    assert not env['rendezvousDocked'](bow,end)
    peerport=Port();a=Map(KIND='PORT',PART=port);b=Map(KIND='PORT',PART=peerport)
    assert not env['rendezvousDocked'](a,b)
    port.HASPARTNER=True;peerport.HASPARTNER=True;port.PARTNER=peerport;peerport.PARTNER=port
    assert env['rendezvousDocked'](a,b)
    peer.LOADED=False
    assert not env['rendezvousEndpoint'](peer)['OK']
    # A small along-axis gap never hides a sideways miss.
    gap=env['rendezvousEndpointGap'](Map(POINT=V((0,0,0)),AXIS=V((0,1,0))),
        Map(POINT=V((3,.1,4)),AXIS=V((0,-1,0))))
    assert abs(gap['GAP']-.1)<1e-10 and gap['SIDE']==5 and gap['ANGLE']==0
    print('PASS: labeled ports first, bow only when absent, invalid tags refuse; actual partner required; lateral gap measured separately')


def check_relative_burns():
    for scenario in ('normal','abort','no-engine','off-vector','already-matched','stale','stage','reserve','impulse','reboot','peer-thrust','packed','dead','active','warp','node','bad-velocity'):
        env,saved=fixture();real=env['_matchLive'];holder=[None]
        ship=NS(BODY=env['SHIP'].BODY,ORBIT=env['SHIP'].ORBIT,STAGENUM=1,AVAILABLETHRUST=2.,
            MASS=1.,THRUST=0.,POSITION=V((0,0,0)),VELOCITY=NS(ORBIT=V((1,0,0))),
            FACING=NS(FOREVECTOR=V((-1,0,0))),DELTAV=NS(VACUUM=2000))
        peer=NS(BODY=ship.BODY,ORBIT=ship.ORBIT,POSITION=V((500,0,0)),ISDEAD=False,THRUST=0,LOADED=True,UNPACKED=True,
            VELOCITY=NS(ORBIT=V((0,0,0))))
        env.update(SHIP=ship,other=peer);env['KUNIVERSE'].ACTIVEVESSEL=ship
        if scenario=='already-matched':ship.VELOCITY.ORBIT=V((0,0,0))
        if scenario=='no-engine':ship.AVAILABLETHRUST=0
        if scenario=='off-vector':ship.FACING.FOREVECTOR=V((0,1,0))
        if scenario=='reboot':saved['rendezvous_active']=True
        def live(guard):
            holder[0]=guard
            return real(guard)
        def wait(dt):
            guard=holder[0]
            if scenario=='off-vector':dt=5
            env['TIME'].SECONDS+=dt
            if scenario=='abort':env['ABORT']=True
            if scenario=='stage':ship.STAGENUM=0
            if scenario=='reserve':ship.DELTAV=NS(VACUUM=0)
            if scenario=='impulse':guard['IMPULSE']=guard['CAP']
            if scenario=='peer-thrust':peer.THRUST=1
            if scenario=='packed':peer.UNPACKED=False
            if scenario=='dead':peer.ISDEAD=True
            if scenario=='active':env['KUNIVERSE'].ACTIVEVESSEL=peer
            if scenario=='warp':env['WARP']=1
            if scenario=='node':env['HASNODE']=True
            if scenario=='bad-velocity':ship.VELOCITY.ORBIT=V((math.nan,0,0))
            if scenario=='stale':env['TIME'].SECONDS+=1
            command=env['_matchThrottle'](1,guard)
            ship.THRUST=command*ship.AVAILABLETHRUST
            relative=ship.VELOCITY.ORBIT-peer.VELOCITY.ORBIT
            if relative.MAG>0:ship.VELOCITY.ORBIT-=relative.NORMALIZED*ship.THRUST/ship.MASS*dt
        def stop():ship.THRUST=0;return True
        env.update(_matchLive=live,fixture_wait=wait,_matchStopThrottle=stop)
        success=env['_matchBurnRel'](peer,V((0,0,0)),20,100)
        assert success==(scenario in ('normal','already-matched')),scenario
        assert ship.THRUST==0,scenario
        assert bool(saved.get('rendezvous_active'))==(scenario not in ('normal','already-matched')),scenario
    print('PASS: real relative-burn loop/lock cutoff: normal/zero correction, Abort/no-engine/off-vector/stale/stage/reserve/impulse/reboot/peer/packing/context/bad-velocity failures')


def check_close_approach():
    env,saved=fixture();original=env['SHIP']
    ship=NS(BODY=original.BODY,ORBIT=original.ORBIT,STAGENUM=1,AVAILABLETHRUST=2.,MASS=1.,
        THRUST=0.,POSITION=V((-1000,0,0)),VELOCITY=NS(ORBIT=V((0,0,0))),
        FACING=NS(FOREVECTOR=V((1,0,0))),DELTAV=NS(VACUUM=2000),CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
    peer=NS(BODY=ship.BODY,ORBIT=ship.ORBIT,POSITION=V((0,0,0)),ISDEAD=False,THRUST=0,LOADED=True,UNPACKED=True,
        VELOCITY=NS(ORBIT=V((0,0,0))))
    env.update(SHIP=ship,other=peer);env['KUNIVERSE'].ACTIVEVESSEL=ship
    guard=[None];active=[False];closest=[1000.];alarms=[];removed=[]
    actual_live=env['_matchLive']
    def live(data):guard[0]=data;return actual_live(data)
    def lock(statement):
        if statement.startswith('LOCK THROTTLE'):active[0]=True
        if statement.startswith('LOCK STEERING') and guard[0] is not None:
            err=guard[0]['DESIRED']-ship.VELOCITY.ORBIT
            if err.MAG>0:ship.FACING.FOREVECTOR=err.NORMALIZED
    def wait(dt):
        if active[0] and guard[0] is not None:
            cmd=env['_matchThrottle'](1,guard[0]);ship.THRUST=cmd*ship.AVAILABLETHRUST
            ship.VELOCITY.ORBIT+=ship.FACING.FOREVECTOR*ship.THRUST*dt
        ship.POSITION+=ship.VELOCITY.ORBIT*dt
        closest[0]=min(closest[0],(ship.POSITION-peer.POSITION).MAG)
        env['TIME'].SECONDS+=dt
    def stop():active[0]=False;ship.THRUST=0;return True
    def alarm(*args):alarms.append(args);return Text('alarm-'+str(len(alarms)))
    env.update(_matchLive=live,fixture_lock=lock,fixture_wait=wait,_matchStopThrottle=stop,
        kacEnsureAlarm=alarm,DELETEALARM=lambda alarm:removed.append(alarm))
    result=env['matchRendezvous'](peer,150,500,100)
    assert result and closest[0]>100 and (ship.POSITION-peer.POSITION).MAG<=150
    assert ship.VELOCITY.ORBIT.MAG<.2 and ship.THRUST==0 and not saved.get('rendezvous_active')
    assert len(alarms)==len(removed)>0
    print('PASS: real MATCH/coast/pulse chain closes1000m -> stand-off, relative speed<0.2, zero thrust; owned KAC waits cleaned (ideal attitude point mass)')


def check_manual_command():
    command=(ROOT/'cmd/rendezvous.ks').read_text().replace(
        'IF DEFINED EXCURSION_RESERVE_DV','IF fixtureDefined()').replace(
        'UNLOCK STEERING.','fixture_unlock().').replace('SAS ON.','SET SAS TO TRUE.')
    for action in ('preview','plan','invalid','reset'):
        env,saved=fixture();saved.update(phase='SCANSAT_OPS',vehicle='Espoir',mission_id='mapping')
        before=saved.copy();rows=[]
        env.update(action=Text(action),targetName=Text('other'),cap=native(500),reserve=native(100),
            RDV_RESERVE_DV=100,MATCH_RESERVE_DV=100,EXCURSION_RESERVE_DV=300,
            HOMECONNECTION=NS(ISCONNECTED=True),RUNPATH=lambda *_:None,RUNONCEPATH=lambda *_:None,
            bootPreamble=lambda:None,bootLibLoadList=lambda *_:None,
            bootMissionProfileId=lambda vehicle,mid:mid,bootArchivePath=lambda path:Text('0:/'+path),
            bootLocalScriptPath=lambda path:Text('1:/'+path),EXISTS=lambda path:True,
            bootMissionProfileIntent=lambda *_:None,applyMissionOverrides=lambda:None,
            fixtureDefined=lambda:True,fixture_unlock=lambda:None,diagnosticArchiveOpen=lambda name:Map(READY=True),
            diagnosticArchiveLine=lambda report,row:rows.append(str(row)),
            diagnosticArchiveClose=lambda *_:True)
        source_call(command,'_cmdRendezvous',env)
        assert saved==before and env['SHIP'].THRUST==0
        assert env['HASNODE']==(action=='plan'),action
        if action in ('preview','plan'):
            assert any('reserve=300' in row for row in rows),rows
            assert any('native-validated' in row for row in rows),rows
    print('PASS: real manual preview/plan commands preserve mission and excursion reserve, preview removes owned node, plan retains it, invalid/reset do not burn')


def check_attitude_command():
    command=(ROOT/'cmd/docktest.ks').read_text().replace('UNLOCK STEERING.','fixture_unlock().')
    for old,new in (('SAS OFF.','SET SAS TO FALSE.'),('SAS ON.','SET SAS TO TRUE.'),('RCS OFF.','SET RCS TO FALSE.')):
        command=command.replace(old,new)
    for action in ('check','align','hold'):
        env,saved=fixture();orig=env['SHIP'];rows=[];alarms=[];deleted=[];cuts=[];locks=[]
        ship=NS(NAME=Text('Chaser'),BODY=orig.BODY,ORBIT=orig.ORBIT,POSITION=V((-150,0,0)),
            FACING=NS(FOREVECTOR=V((0,1,0))),ANGULARVEL=V((0,0,0)),VELOCITY=NS(ORBIT=V((0,0,0))),
            THRUST=0,LOADED=True,UNPACKED=True,ISDEAD=False,
            CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
        peer=NS(NAME=Text('Target'),BODY=orig.BODY,ORBIT=orig.ORBIT,POSITION=V((0,0,0)),
            FACING=NS(FOREVECTOR=V((-1,0,0))),ANGULARVEL=V((0,0,0)),VELOCITY=NS(ORBIT=V((0,0,0))),
            THRUST=0,LOADED=True,UNPACKED=True,ISDEAD=False)
        for ves in (ship,peer):
            ves.PARTSTAGGED=lambda tag:KItems()
            ves.BOUNDS=NS(FURTHESTCORNER=lambda axis,ves=ves:ves.POSITION+axis*4)
        env.update(SHIP=ship,other=peer,action=Text(action),targetName=Text('Target'),portTag=Text('docking_port'),
            SAS=True,RCS=True,HOMECONNECTION=NS(ISCONNECTED=True),
            RUNPATH=lambda *_:None,RUNONCEPATH=lambda *_:None,bootPreamble=lambda:None,bootLibLoad=lambda _:None,
            diagnosticArchiveOpen=lambda name:Map(READY=True),diagnosticArchiveLine=lambda report,row:rows.append(str(row)),
            diagnosticArchiveClose=lambda *_:True,rendezvousTarget=lambda _:peer,
            kacEnsureAlarm=lambda *args:alarms.append(args) or Text('hold-alarm'),DELETEALARM=deleted.append,
            thrustCutoffOk=lambda *args:cuts.append(args) or True,fixture_unlock=lambda:None)
        saved['phase']='SCANSAT_OPS';env['KUNIVERSE'].ACTIVEVESSEL=ship
        wanted=[ship.FACING]
        class Rotation:
            def __init__(self,axis):self.axis=axis
            def __mul__(self,facing):wanted[0]=NS(FOREVECTOR=self.axis);return wanted[0]
        def wait(dt):
            if locks:ship.FACING=wanted[0]
            if action=='hold':env['KUNIVERSE'].ACTIVEVESSEL=peer;dt=100
            env['TIME'].SECONDS+=dt
        env.update(ROTATEFROMTO=lambda a,b:Rotation(b),fixture_wait=wait,fixture_lock=locks.append)
        source_call(command,'_cmdDocktest',env)
        assert env['RCS'] is True and ship.THRUST==0 and peer.THRUST==0
        if action=='check':assert not locks and not cuts and not alarms
        else:
            assert cuts and len(alarms)==1 and deleted==['hold-alarm']
            if action=='align':
                assert any('aligned-at-stand-off' in row for row in rows)
                assert env['TIME'].SECONDS>=1001
            else:assert any('timeout' in row for row in rows) and env['TIME'].SECONDS>=1600
        assert not any('docked=True' in row for row in rows)
    print('PASS: actual check/align/hold command paths,1s settled alignment, background target hold,600s resident expiry, KAC cleanup/RCS restoration; no bow docking claim')


def check_wiring():
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'lambert' in closure(['rdv_plan'],deps)
    for root in ('rdv_plan','maneuver_rendezvous'):
        assert 'rendezvous_geometry' in closure([root],deps)
    for source in (G,P,M):assert 'VELOCITYAT(' not in source
    phase=function_body(P,'phaseRendezvous')
    assert 'REMOVE ' not in phase and phase.count('executeManeuver()')==1
    for name in ('rendezvous','docktest'):
        command=(ROOT/f'cmd/{name}.ks').read_text()
        assert not command_entrypoint_errors(command)
        assert 'missionOverride' not in command and 'REBOOT.' not in command
    dock=(ROOT/'cmd/docktest.ks').read_text()
    assert 'kacEnsureAlarm(' in dock and 'DELETEALARM(alarm)' in dock
    assert 'LOCK THROTTLE TO' not in dock and 'STAGE.' not in dock
    assert 'LOCAL initialFacing IS SHIP:FACING' in dock and 'ROTATEFROMTO(initialAxis,line_:NORMALIZED)*initialFacing' in dock
    assert 'TIME:SECONDS-settledSince >= 1' in dock
    assert 'rendezvousDocked(ownEnd,peerEnd)' in dock
    print('PASS: phase/command dependencies, failure preserves node, no future VELOCITYAT, KAC+resident rehearsal, no mission replacement/staging/contact thrust')


if __name__=='__main__':
    check_geometry_and_node_ownership()
    check_budgets_and_native_intercept()
    check_endpoints()
    check_relative_burns()
    check_close_approach()
    check_manual_command()
    check_attitude_command()
    check_wiring()
