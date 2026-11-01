"""Scheduled capture reuse after reboot; real phase/guards and independent impulse conics."""
import math
from types import SimpleNamespace as NS

import check_entry_landing as entry
import check_survey_orbit as physics
import check_relay_constellation as harness
from check_codebase import ROOT
from check_espoir_fleet import Items, Text, native, profile

SOURCE=(ROOT/'lib/capture.ks').read_text().replace('REMOVE nd.','fixture_remove(nd).')


def fixture():
    body=NS(NAME=Text('Minmus'),RADIUS=60000,MU=1.7658e9,SOIRADIUS=2247428,ATM=NS(EXISTS=False))
    pe=468300;ap=1041045;rp=body.RADIUS+pe;ra=body.RADIUS+ap
    inc=math.radians(21.51);lan=math.radians(40)
    pos=(rp*math.cos(lan),rp*math.sin(lan),0)
    tangent=(-math.sin(lan)*math.cos(inc),math.cos(lan)*math.cos(inc),math.sin(inc))
    normal=physics.unit(physics.cross(pos,tangent));radial=physics.unit(pos)
    required=187.8846;incoming=math.sqrt(body.MU*(2/rp-2/(rp+ra)))+required
    sma=1/(2/rp-incoming**2/body.MU)
    ship=physics.Ship();ship.BODY=body;ship.THRUST=0;ship.DELTAV=NS(VACUUM=3312.75)
    ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    ship.ORBIT=NS(ECCENTRICITY=1-rp/sma,SEMIMAJORAXIS=sma,PERIAPSIS=pe,APOAPSIS=-648700,
        HASNEXTPATCH=True,NEXTPATCHETA=20000,INCLINATION=21.51,LAN=40)
    clock=NS(SECONDS=5291303.5);epoch=5292633.3
    class Node:
        TIME=epoch;PROGRADE=-required;NORMAL=0;RADIALOUT=0;alive=True
        ETA=property(lambda self:self.TIME-clock.SECONDS)
        DELTAV=property(lambda self:NS(MAG=math.sqrt(self.PROGRADE**2+self.NORMAL**2+self.RADIALOUT**2)))
        @property
        def ORBIT(self):
            assert self.alive,'detached capture node inspected'
            vel=physics.add(physics.mul(tangent,incoming+self.PROGRADE),
                physics.add(physics.mul(normal,self.NORMAL),physics.mul(radial,self.RADIALOUT)))
            return physics.Orbit(body,pos,vel,self.TIME)
    node=Node();state=native(dict(phase='CAPTURE',mission_id='minmus_orbital_surveyor',launch_time=5143320,
        burn_pending='true',burn_started='false',burn_phase='CAPTURE',burn_body='Minmus',
        burn_mission_id='minmus_orbital_surveyor',burn_launch_time=5143320,burn_node_time=epoch,
        burn_start_time=epoch-5.3,burn_dv=required))
    events=[];world=dict(executed=False,late=None)
    env=dict(profile('minmus_orbital_surveyor'),SHIP=ship,TIME=clock,ETA=NS(PERIAPSIS=epoch-clock.SECONDS),
        KUNIVERSE=NS(ACTIVEVESSEL=ship),WARP=0,ABORT=False,HASNODE=True,NEXTNODE=node,ALLNODES=Items([node]),
        phaseShouldYield=False,MAX_RETRIES=5,MAX=max,ABS=abs,CAPTURE_ACCEPT_BOUND=0,
        COS=lambda angle:math.cos(math.radians(angle)),SIN=lambda angle:math.sin(math.radians(angle)),
        stateGet=state.get,stateGetNum=state.get,missionTargetBody=lambda:body,midcourseClearReviewAlarm=lambda:None,
        maneuverBurnInterrupted=lambda:state.get('burn_pending')=='true' and state.get('burn_started')=='true',
        _captureRecoverResidual=lambda _:False,_captureContinueFlyby=lambda _:False,
        orbitSummary=lambda:None,fixture_wait=lambda dt:events.append(('wait',dt)),
        yieldToPrompt=lambda:events.append('hold'),fixture_log=lambda:None,fixture_text=Text,
        mLog=lambda _:None,mLogWarn=lambda _:None,mLogError=lambda _:None)
    def forbidden(*_):raise AssertionError('scheduled capture was replanned')
    def remove(nd):assert nd is node;node.alive=False;env['HASNODE']=False;events.append('remove')
    def execute():
        assert node.alive and env['NEXTNODE'] is node and state['burn_started']=='false'
        assert node.TIME==epoch and abs(node.DELTAV.MAG-required)<1e-10
        world['executed']=True;ship.ORBIT=node.ORBIT;env['HASNODE']=False;node.alive=False
        events.append('execute');return True
    def advance(_):state['phase']=Text('SHAPE');events.append('advance')
    env.update(planCapture=forbidden,fixture_remove=remove,executeManeuver=execute,nextPhase=advance,
        xferSeq=env['SEQUENCE'])
    env['_captureUnflownNode']=lambda target:entry.call(SOURCE,'_captureUnflownNode',env,target)
    return env,ship,state,node,events,world


def run(env):harness.invoke(SOURCE,'phaseCapture',env)


def check_native_scheduled_capture():
    env,ship,state,node,events,world=fixture()
    assert env['_captureUnflownNode'](ship.BODY)
    run(env)
    assert world['executed'] and events==['execute','advance']
    assert state['phase']=='SHAPE' and ship.ORBIT.ECCENTRICITY<1
    assert abs(ship.PERIAPSIS-468300)<1e-6 and abs(ship.APOAPSIS-1041045)<1e-6
    assert node.TIME==5292633.3 # Executor receives the original epoch, not "burn now".
    print('PASS: reported20-minute unflown187.8846m/s Minmus capture reuses its original node/epoch without another planner, produces the independent468.3x1041.045km bound orbit and advances SHAPE')


def check_saved_capture_guards():
    changes={
        'missing-intent':lambda e,s,st,n:st.pop('burn_pending'),
        'started':lambda e,s,st,n:st.update(burn_started=Text('true')),
        'phase':lambda e,s,st,n:st.update(burn_phase=Text('BPLANE')),
        'current-phase':lambda e,s,st,n:st.update(phase=Text('SHAPE')),
        'mission':lambda e,s,st,n:st.update(burn_mission_id=Text('other')),
        'launch':lambda e,s,st,n:st.update(burn_launch_time=1),
        'body':lambda e,s,st,n:st.update(burn_body=Text('Mun')),
        'foreign-node':lambda e,s,st,n:setattr(n,'TIME',n.TIME+1),
        'extra-node':lambda e,s,st,n:e['ALLNODES'].append(NS()),
        'no-node':lambda e,s,st,n:e.update(HASNODE=False),
        'changed-dv':lambda e,s,st,n:setattr(n,'PROGRADE',-180),
        'wrong-direction':lambda e,s,st,n:setattr(n,'PROGRADE',187.8846),
        'normal':lambda e,s,st,n:setattr(n,'NORMAL',1),
        'radial':lambda e,s,st,n:setattr(n,'RADIALOUT',1),
        'nan-dv':lambda e,s,st,n:st.update(burn_dv=math.nan),
        'expired':lambda e,s,st,n:setattr(e['TIME'],'SECONDS',n.TIME+1),
        'late':lambda e,s,st,n:setattr(e['TIME'],'SECONDS',n.TIME-59),
        'off-pe':lambda e,s,st,n:setattr(e['ETA'],'PERIAPSIS',1000),
        'bound':lambda e,s,st,n:setattr(s.ORBIT,'ECCENTRICITY',.9),
        'peri-min':lambda e,s,st,n:e.update(CAPTURE_MIN_PE=469000),
        'peri-max':lambda e,s,st,n:e.update(CAPTURE_MAX_PE=467000),
        'target-changed':lambda e,s,st,n:e.update(TARGET_AP=1200000),
        'fuel':lambda e,s,st,n:setattr(s.DELTAV,'VACUUM',187),
        'reserve':lambda e,s,st,n:setattr(s.DELTAV,'VACUUM',480),
        'invalid-fuel':lambda e,s,st,n:setattr(s.DELTAV,'VACUUM',math.nan),
        'abort':lambda e,s,st,n:e.update(ABORT=True),
        'warp':lambda e,s,st,n:e.update(WARP=1),
        'inactive':lambda e,s,st,n:setattr(e['KUNIVERSE'],'ACTIVEVESSEL',NS()),
        'thrust':lambda e,s,st,n:setattr(s,'THRUST',1),
        'raw':lambda e,s,st,n:setattr(s.CONTROL,'MAINTHROTTLE',.1),
        'pilot':lambda e,s,st,n:setattr(s.CONTROL,'PILOTMAINTHROTTLE',.1),
    }
    for fault,change in changes.items():
        env,ship,state,node,events,world=fixture();change(env,ship,state,node);before=state.copy()
        assert not env['_captureUnflownNode'](ship.BODY),fault
        if fault!='no-node':
            run(env)
            assert state==before and node.alive and not world['executed'] and events==['hold'],fault
    print(f'PASS: {len(changes)} unowned/flown/edited/late/unsafe/unaffordable/control contexts cannot authorize capture reuse or delete a retained node')


def check_revalidation_after_budget_io():
    for fault in ('node','fuel','abort','replacement'):
        env,ship,state,node,events,world=fixture();original=env['_captureUnflownNode'];calls=[]
        def validate(target):
            calls.append(True)
            if len(calls)==3:
                if fault=='node':node.TIME+=1
                if fault=='fuel':ship.DELTAV.VACUUM=400
                if fault=='abort':env['ABORT']=True
                if fault=='replacement':
                    replacement=type(node)();node.alive=False
                    env.update(NEXTNODE=replacement,ALLNODES=Items([replacement]))
            return original(target)
        env['_captureUnflownNode']=validate;before=state.copy();run(env)
        assert len(calls)==3 and events==['hold'] and state==before and not world['executed']
        assert env['NEXTNODE'].alive
        if fault=='replacement':assert not node.alive and env['NEXTNODE'] is not node
        else:assert node.alive
    print('PASS: scheduled capture is revalidated again after budget/log I/O; changed/replaced node, reserve or Abort retains the plan and never reaches the executor')


if __name__=='__main__':
    check_native_scheduled_capture()
    check_saved_capture_guards()
    check_revalidation_after_budget_io()
