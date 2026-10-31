"""Native-patch API semantics with independent Kepler states; not KSP."""
import math
import re
from types import SimpleNamespace as NS

import numpy as np
import check_entry_landing as entry
from check_codebase import ROOT,function_body,mask,command_entrypoint_errors
from check_deorbit_geometry import Vec,dot,cross
from check_espoir_fleet import native,Map,Items

MATH=(ROOT/'lib/lib_bplane_math.ks').read_text()
ARRIVAL=(ROOT/'lib/arrival_bplane.ks').read_text()


class Vector(Vec):
    SQRMAGNITUDE=property(lambda self:float(np.dot(self,self)))


def measurement(mu=3.0136321e11,radius=320000,pe=70000,vinf=1200,distance=5e9,hand=1):
    rp=radius+pe;ecc=1+rp*vinf**2/mu;sma=-mu/vinf**2;latus=rp*(1+ecc)
    # Fix an arbitrary non-equatorial orientation; evaluate an independent
    # analytic Kepler state far before the actual encounter interval.
    ehat=Vector((.3,.4,math.sqrt(.75)))
    qhat=Vector(np.cross(ehat,(0,1,0)));qhat=qhat/qhat.MAG
    cosine=(latus/distance-1)/ecc;sine=-math.sqrt(1-cosine**2)
    r=distance*(cosine*ehat+sine*qhat)
    v=math.sqrt(mu/latus)*(-sine*ehat+(ecc+cosine)*qhat)
    body=NS(NAME='Duna',MU=mu,RADIUS=radius,POSITION=Vector((3e10,-7e9,5e9)),ANGULARVEL=Vector((0,1,0)))
    patch=NS(POSITION=r+body.POSITION,VELOCITY=NS(ORBIT=v),SEMIMAJORAXIS=sma,
        ECCENTRICITY=ecc,PERIAPSIS=pe,INCLINATION=45,LAN=12)
    hit=dict(patch=patch,entryUt=9.4e6)
    def forbidden(*_):raise AssertionError('measurement used vessel/body future wrappers instead of the selected patch')
    env=dict(findArrivalPatch=lambda *_:hit,TIME=NS(SECONDS=5114959),
        POSITIONAT=forbidden,VELOCITYAT=forbidden,_BPLANE_MEASURE_LOGGED=False,_BPLANE_BAD_MEASURE_LOGGED=False,
        V=lambda *xs:Vector(xs),VDOT=dot,VCRS=lambda a,b:Vector(hand*cross(a,b)),
        SQRT=math.sqrt,LEX=lambda *xs:Map(zip(xs[::2],xs[1::2])),fixture_log=lambda:None,
        VANG=lambda a,b:math.degrees(math.acos(np.clip(dot(a,b)/(a.MAG*b.MAG),-1,1))))
    return env,body,patch,ehat,qhat


def check_conic_measurements_and_handedness():
    for mu,radius,pe,vinf in ((3.0136321e11,320000,70000,1200),(3.0136321e11,320000,33066707,1200),
                              (6.5138398e10,200000,15000,272.804),(1.7658e9,60000,15000,200)):
        for distance in (radius+pe+1e6,5e9,3e10):
            for hand in (-1,1):
                env,body,patch,ehat,qhat=measurement(mu,radius,pe,vinf,distance,hand)
                result=entry.call(MATH,'measureArrival',env,0,body)
                assert result,(mu,radius,pe,distance,hand)
                ecc=patch.ECCENTRICITY
                expected_s=ehat/ecc+qhat*math.sqrt(1-1/ecc**2)
                expected_b=ehat-dot(ehat,expected_s)*expected_s;expected_b/=expected_b.MAG
                expected_mag=abs(patch.SEMIMAJORAXIS)*math.sqrt(ecc**2-1)
                assert np.allclose(result['S'],expected_s,atol=2e-8)
                assert np.allclose(result['bHat'],expected_b,atol=2e-8)
                assert math.isclose(result['vinf2'],vinf**2,rel_tol=1e-12)
                assert math.isclose(result['bMag'],expected_mag,rel_tol=1e-12)
                assert math.isclose(math.hypot(result['bt'],result['br']),expected_mag,rel_tol=1e-12)
                # Independently recover Pe from B and hyperbolic energy.
                scale=mu/vinf**2
                assert math.isclose(math.hypot(scale,result['bMag'])-scale-radius,pe,abs_tol=1e-7)
                target=entry.call(MATH,'targetBplaneVector',env,body,result,pe,-1,-1,True)
                assert math.isclose(target['bt'],result['bt'],rel_tol=1e-8,abs_tol=.01)
                assert math.isclose(target['br'],result['br'],rel_tol=1e-8,abs_tol=.01)
    assert 'POSITIONAT(' not in re.sub(r'//[^\n]*','',function_body(MATH,'measureArrival'))
    print('PASS: actual measurement recovers independent Duna/Mun/Minmus Pe/B/asymptotes at near and very distant extrapolation, in both handednesses; future body motion and pending vessel nodes cannot enter the selected patch state')


def check_native_consistency_guards():
    for fault in ('legacy-state','energy','momentum','ecc','a','r-nan','v-nan','missing'):
        env,body,patch,_,_=measurement()
        if fault=='legacy-state':
            # Native log: r~30 billion metres and v8777m/s were paired
            # with a Duna conic whose Pe was actually70km/25,568km.
            patch.POSITION=body.POSITION+Vector((3.00319935e10,0,0))
            patch.VELOCITY.ORBIT=Vector((0,8777.013,0))
        if fault=='energy':patch.VELOCITY.ORBIT*=2
        if fault=='momentum':patch.VELOCITY.ORBIT=patch.VELOCITY.ORBIT.MAG*(patch.POSITION-body.POSITION).NORMALIZED
        if fault=='ecc':patch.ECCENTRICITY=1.1
        if fault=='a':patch.SEMIMAJORAXIS=1
        if fault=='r-nan':patch.POSITION[0]=math.nan
        if fault=='v-nan':patch.VELOCITY.ORBIT[0]=math.nan
        if fault=='missing':env['findArrivalPatch']=lambda *_:0
        assert entry.call(MATH,'measureArrival',env,0,body)==0,fault
    print('PASS: observed-scale mixed frame, bad energy/angular momentum/eccentricity, nonfinite vectors and missing/nonhyperbolic patches cannot supply an apparently useful B-vector')


def budget_fixture():
    saved=dict(launch_time=native(5032669),mission_id='duna_lander',phase='BPLANE')
    env=dict(stateGet=saved.get,stateGetNum=saved.get,stateSet=lambda key,value:saved.update({key:value}),
        findArrivalPatch=lambda *_:dict(patch=True),LEXICON=lambda *xs:Map(zip(xs[::2],xs[1::2])),
        maneuverBurnInterrupted=lambda:False,SHIP=NS(BODY=NS(NAME='Sun'),DELTAV=NS(VACUUM=2091)),
        BPLANE_TRIM_DV_CAP=150,BPLANE_TRIM_TOTAL_DV_CAP=150,BPLANE_TRIM_RESERVE_DV=1000)
    for name in ('_bplaneTrimSpent','_bplaneTrimCap','_bplaneReserveCorrection','_bplaneReservationCredit'):
        env[name]=lambda *args,name=name:entry.call(ARRIVAL,name,env,*args)
    return env,saved,NS(NAME='Duna'),NS(TIME=5115043.9118548,DELTAV=NS(MAG=18.943128))


def check_reboot_reservations():
    env,saved,body,node=budget_fixture()
    for _ in range(3):env['_bplaneReserveCorrection'](node,body)
    assert saved['bplane_budget_spent']==18.943128 # Native report double-charged37.886256.
    node.DELTAV.MAG=20;env['_bplaneReserveCorrection'](node,body)
    node.DELTAV.MAG=10;env['_bplaneReserveCorrection'](node,body)
    assert saved['bplane_budget_spent']==20 and saved['bplane_budget_reservation']['COST']==20
    node.TIME+=1000;node.DELTAV.MAG=130
    env['_bplaneReserveCorrection'](node,body)
    assert saved['bplane_budget_spent']==150
    credit=env['_bplaneReservationCredit'](node,body)
    assert credit==130 and env['_bplaneTrimCap'](body,150,credit)==130
    assert env['_bplaneTrimCap'](body,150)==0 # Fresh node gets no false refund.
    env['maneuverBurnInterrupted']=lambda:True
    assert env['_bplaneReservationCredit'](node,body)==0
    # Simulate a shutdown after the reservation record but before spent.
    for changed_node in (False,True):
        env,saved,body,node=budget_fixture()
        def interrupted_write(key,value):
            if key=='bplane_budget_spent' and 'bplane_budget_reservation' in saved:raise RuntimeError('power cut')
            saved[key]=value
        env['stateSet']=interrupted_write
        try:env['_bplaneReserveCorrection'](node,body)
        except RuntimeError:pass
        else:raise AssertionError('fixture did not interrupt the second write')
        env['stateSet']=lambda key,value:saved.update({key:value})
        assert env['_bplaneTrimSpent'](body)==18.943128
        if changed_node:node.TIME+=1000;node.DELTAV.MAG=2
        env['_bplaneReserveCorrection'](node,body)
        assert math.isclose(saved['bplane_budget_spent'],18.943128+(2 if changed_node else 0))
    print('PASS: actual pending18.943128m/s correction pays once across reboot/partial ledger writes; growing/changed nodes pay extra, only the same unflown reservation receives cumulative-cap credit, and interrupted execution never receives reuse credit')


def check_archive_snapshot_command():
    source=(ROOT/'cmd/bplanecheck.ks').read_text()
    assert not command_entrypoint_errors(source)
    assert not re.search(r'\b(?:LOCK|STAGE|REMOVE|ADD|REBOOT)\b|executeManeuver\(',mask(source))
    source=source.replace(' + HASNODE + ',' + fixtureHasNode() + ')
    source=source.replace(' + (measured <> 0) + ',' + fixtureMeasurementFlag(measured) + ')
    # Native KerboScript permits implicit vector/scalar text concatenation.
    class TextVector(Vector):
        def __radd__(self,value):
            if isinstance(value,str):return value+str(tuple(self))
            return super().__radd__(value)
    for case in ('ok','bad-measurement','no-patch','no-link','warp','thrust','pilot','inactive'):
        env,body,patch,_,_=measurement()
        for key in ('PERIAPSIS','INCLINATION','LAN','SEMIMAJORAXIS','ECCENTRICITY'):
            setattr(patch,key,native(getattr(patch,key)))
        body.POSITION=TextVector(body.POSITION);patch.POSITION=TextVector(patch.POSITION)
        patch.VELOCITY.ORBIT=TextVector(patch.VELOCITY.ORBIT)
        ship=NS(NAME='Espoir-Duna-Lander2',THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
        state=dict(vehicle='Espoir',mission_id='duna_lander',phase='BPLANE',last_burn_report='strict residual remains unchanged')
        hit=dict(patch=patch,entryUt=native(9482847));rows=[];events=[]
        env.update(WARP=0,SHIP=ship,KUNIVERSE=NS(ACTIVEVESSEL=ship),HASNODE=True,
            TIME=NS(SECONDS=native(5115049)),HOMECONNECTION=NS(ISCONNECTED=True),
            fixtureHasNode=lambda:'True',fixtureMeasurementFlag=lambda value:str(value!=0),
            stateGet=state.get,RUNPATH=lambda *_:None,bootPreamble=lambda:None,bootLibLoad=lambda *_:None,
            bootApplyMissionConfig=lambda *_:True,getTarget=lambda:'Duna',BODYEXISTS=lambda *_:True,BODY=lambda *_:body,
            findArrivalPatch=lambda *_:hit,measureArrival=lambda *_:Map(vinf2=native(1200**2),bMag=native(400000),
                bt=native(0),br=native(-400000),S=TextVector((1,0,0)),hHat=TextVector((0,1,0)),eHat=TextVector((0,0,1))),
            diagnosticArchiveOpen=lambda *_:Map(READY=case!='no-link'),
            diagnosticArchiveLine=lambda report,row:rows.append(row),
            diagnosticArchiveClose=lambda *_:events.append('verified'))
        if case=='bad-measurement':env['measureArrival']=lambda *_:0
        if case=='no-patch':env['findArrivalPatch']=lambda *_:0
        if case=='warp':env['WARP']=1
        if case=='thrust':ship.THRUST=1
        if case=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if case=='inactive':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        before=state.copy();entry.call(source,'_cmdBplanecheck',env)
        recorded=case in ('ok','bad-measurement','no-patch')
        assert bool(rows)==recorded and bool(events)==recorded and state==before
        assert env['HASNODE'] and not ship.CONTROL.MAINTHROTTLE
        if case=='ok':assert any('geometry vinf2=' in row for row in rows)
        if case=='bad-measurement':assert any('valid=False' in row for row in rows)
        if recorded:assert any(state['last_burn_report'] in row for row in rows)
    print('PASS: read-only archive command records native patch/vectors, validity and unchanged strict executor evidence without editing nodes/phase/controls; invalid measurement, no encounter, no link and live-control cases are explicit')


def recovery_fixture():
    import check_midcourse as mid
    from arrival_fixture import EventEta
    env,saved,events,alarms,body,hit=mid.retry_environment()
    body.NAME='Duna';body.RADIUS=320000;body.SOIRADIUS=47921949;body.ATM.EXISTS=True;body.ATM.HEIGHT=50000
    ship=env['SHIP'];ship.BODY.NAME='Sun';ship.BODY.ATM.EXISTS=False;ship.PERIAPSIS=13335008300
    ship.THRUST=0;ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    env['KUNIVERSE'].ACTIVEVESSEL=ship;env['TIME'].SECONDS=5115049.21
    hit['entryUt']=9482847.308;hit['patch'].PERIAPSIS=54872
    ship.ORBIT.NEXTPATCHETA=hit['entryUt']-env['TIME'].SECONDS
    hit['patch'].ETA=EventEta(env['TIME'],hit['entryUt']+10000)
    hit['patch'].HASNEXTPATCH=False
    env.update(CAPTURE_PE=70000,BPLANE_PE_TOL=2000,BPLANE_REVIEW_MIN_PE=10000,
        BPLANE_CAPTURE_MARGIN=-1,BPLANE_TRIM_RESERVE_DV=1000,
        BPLANE_TRIM_DV_CAP=150,BPLANE_TRIM_TOTAL_DV_CAP=250,REFINE_BPLANE_DV_CAP=50,
        NEXTNODE=NS(TIME=5115043.9118548,DELTAV=NS(MAG=.057702484)),HASNODE=True,
        arrivalRequiredCaptureDv=lambda *_:885.41,thrustCutoffOk=lambda:True,fixture_log=lambda:None)
    ship.DELTAV=NS(VACUUM=2072.23)
    saved.update(phase='BPLANE',mission_id='duna_lander',launch_time=native(5032669),
        burn_phase='BPLANE',burn_body='Sun',burn_pending='true',burn_started='true',
        burn_abort_reason='residual-outside-tolerance',burn_abort_residual=.057702484,
        burn_dv=18.943128,burn_node_time=env['NEXTNODE'].TIME,
        bplane_budget_id='Duna:5032669',bplane_budget_spent=37.886256,
        last_burn_report=native('STATS last-burn reason=live-thrust-axis-trim cutoffFault=residual-outside-tolerance shutdownAttempted=False thrustStopped=True'),
        bplane_budget_reservation=Map(ID='Duna:5032669',UT=env['NEXTNODE'].TIME,COST=18.943128,TOTAL=37.886256,
            MISSION='duna_lander',PHASE='BPLANE',BODY='Sun'))
    # Match the fixture scalar's display convention (kOS omits the .0).
    saved['bplane_budget_id']='Duna:'+str(saved['launch_time'])
    saved['bplane_budget_reservation']['ID']=saved['bplane_budget_id']
    env['maneuverBurnInterrupted']=lambda:saved.get('burn_started')=='true' and saved.get('burn_pending')=='true'
    for name in ('_bplaneTrimSpent','_bplaneTrimCap','_bplaneRecoverStoppedTrim'):
        env[name]=lambda *args,name=name:entry.call(ARRIVAL,name,env,*args)
    env['_bplaneEnsureSoiAlarm']=lambda *_:events.append(('soi-alarm',))
    def handoff():
        assert env['HASNODE'] and abs(env['NEXTNODE'].TIME-saved['burn_node_time'])<.01
        events.append(('handoff',));env['HASNODE']=False
        for key in ('burn_pending','burn_started','burn_phase','burn_abort_reason'):saved.pop(key,None)
    env['maneuverAcceptHandoff']=handoff
    return env,saved,events,alarms,body,hit


def check_stopped_trim_coast_recovery():
    import check_midcourse as mid
    # Exercise the actual phase's reboot entry as well as the guard itself.
    env,saved,_,_,_,_=recovery_fixture()
    entry.call(ARRIVAL,'phaseBplane',env)
    assert saved['phase']=='COAST_1HALF' and not env['phaseShouldYield'] and not env['HASNODE']
    for kac in (False,True):
        env,saved,events,alarms,body,hit=recovery_fixture()
        env['ADDONS'].KAC.AVAILABLE=kac
        original=saved['last_burn_report'];spent=saved['bplane_budget_spent']
        assert env['_bplaneRecoverStoppedTrim']()
        assert saved['phase']=='COAST_1HALF' and not env['HASNODE'] and not env['maneuverBurnInterrupted']()
        assert saved['last_burn_report']==original and saved['bplane_budget_spent']==spent
        assert events.index(('soi-alarm',))<events.index(('handoff',))
        assert not env['phaseShouldYield'] and 'bplane_midcourse_retry' not in saved
        wake=saved['midcourse_refine_ut']
        def enter(label,orient,health,deadline):
            assert deadline==wake;return 1
        def wait(target,ut,*_):
            assert target is body and ut==wake;env['TIME'].SECONDS=ut
        env.update(enterSolarCoast=enter,waitUntilOrSOI=wait)
        mid.ks.call('phaseCoast1Half',env)
        assert saved['phase']=='REFINE_BPLANE' and not alarms and not env['phaseShouldYield']
    for fault in ('legacy','wrong-mission','wrong-launch','wrong-body','wrong-phase','foreign-node','large-residual','relative-residual',
                  'bad-report','forced','not-stopped','nan','node-residual','no-node','thrust','pilot','abort','warp','inactive',
                  'late','no-patch','unsafe-pe','fuel','cap','cutoff','no-midcourse'):
        env,saved,events,alarms,body,hit=recovery_fixture()
        if fault=='legacy':saved.pop('bplane_budget_reservation')
        if fault=='wrong-mission':saved['mission_id']='another'
        if fault=='wrong-launch':saved['launch_time']=native(123)
        if fault=='wrong-body':env['SHIP'].BODY.NAME='Kerbin'
        if fault=='wrong-phase':saved['phase']='REFINE_BPLANE'
        if fault=='foreign-node':env['NEXTNODE'].TIME+=10
        if fault=='large-residual':saved['burn_abort_residual']=.31
        if fault=='relative-residual':saved['burn_dv']=1
        if fault=='bad-report':saved['burn_abort_reason']='live-command-stale'
        if fault=='forced':saved['last_burn_report']=native(str(saved['last_burn_report']).replace('shutdownAttempted=False','shutdownAttempted=True'))
        if fault=='not-stopped':saved['last_burn_report']=native(str(saved['last_burn_report']).replace('thrustStopped=True','thrustStopped=False'))
        if fault=='nan':saved['burn_abort_residual']=math.nan
        if fault=='node-residual':env['NEXTNODE'].DELTAV.MAG=1
        if fault=='no-node':env['HASNODE']=False
        if fault=='thrust':env['SHIP'].THRUST=.1
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='abort':env['ABORT']=True
        if fault=='warp':env['WARP']=1
        if fault=='inactive':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='late':hit['entryUt']=env['TIME'].SECONDS+800
        if fault=='no-patch':env['findArrivalPatch']=lambda *_:0
        if fault=='unsafe-pe':hit['patch'].PERIAPSIS=49000
        if fault=='fuel':env['SHIP'].DELTAV.VACUUM=1935.40
        if fault=='cap':env['REFINE_BPLANE_DV_CAP']=.3
        if fault=='cutoff':env['thrustCutoffOk']=lambda:False
        if fault=='no-midcourse':env['xferSeq']=Items(['BPLANE','COAST','CAPTURE'])
        before=saved.copy()
        assert not env['_bplaneRecoverStoppedTrim'](),fault
        assert saved==before and not events and not alarms,fault
    print('PASS: recorded0.057702484m/s tail only resumes an intent-bound, physically stopped early burn into the real timed midpoint/refinement path; strict report/spent ledger/capture goals remain, and legacy/late/unsafe/unfunded/unbound failures retain review')


if __name__=='__main__':
    check_conic_measurements_and_handedness()
    check_native_consistency_guards()
    check_reboot_reservations()
    check_archive_snapshot_command()
    check_stopped_trim_coast_recovery()
