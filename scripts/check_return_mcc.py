"""Return-corridor regressions using source expressions and two-body fixtures.

Not a kOS VM or a KSP flight test. Run: python3 -B scripts/check_return_mcc.py
"""
import math
import re
from pathlib import Path
from types import SimpleNamespace as NS

from check_launch_and_staging import body, evaluate
import check_landing_guidance as ks
from check_deorbit_geometry import Vec

ROOT = Path(__file__).resolve().parents[1]
MCC = (ROOT / 'lib/maneuver_mcc.ks').read_text()
AERO = (ROOT / 'lib/aerobrake.ks').read_text()
TARGETING = (ROOT / 'lib/maneuver_targeting.ks').read_text()
RECOVERY = (ROOT / 'cmd/reentrype.ks').read_text()
PLAN = (ROOT / 'lib/maneuver_plan.ks').read_text()
REPAIR = (ROOT / 'lib/reentry_pe.ks').read_text()
ks.SOURCES+='\n'+PLAN+'\n'+RECOVERY+'\n'+REPAIR


def check_gates():
    from check_minmus_kolniya import execute
    budget = body(MCC, '_mccReturnBudget')
    for cap,fuel,expected in [(150,480,150),(150,180,130),(150,51,1),(150,50,0),(150,0,0),
                              (-1,813.434,763.434),(-1,180,130),(-1,50,0),(-1,49,0),(0,480,0),
                              (-1,math.nan,0),(-1,math.inf,0),(math.nan,480,0),(math.inf,480,0)]:
        actual=execute(budget,dict(MCC_RETURN_DV_CAP=cap,MCC_RETURN_RESERVE_DV=50,
                                  SHIP=NS(DELTAV=NS(VACUUM=fuel))))
        assert abs(actual-expected)<1e-9,(cap,fuel,actual)
    for reserve in (-1,math.nan,math.inf):
        assert execute(budget,dict(MCC_RETURN_DV_CAP=-1,MCC_RETURN_RESERVE_DV=reserve,
                                  SHIP=NS(DELTAV=NS(VACUUM=813))))==0
    corridor = re.search(r'RETURN (pe >=.*?)\.',
                         body(MCC, '_mccAerobrakePatchSafe'), re.S)[1]
    for pe, allowed in [(2200000, False), (70000, False), (54001, False),
                        (54000, True), (53000, True), (52000, True),
                        (51999, False), (-100, False)]:
        assert evaluate(corridor, pe=pe, target=None, targetPe=53000,
                        _mccAerobrakeSafePeMin=lambda *_: 52000,
                        _mccAerobrakeSafePeMax=lambda *_: 54000) == allowed
    phase = body(MCC, '_mccReturn')
    rejection = re.search(r'IF (NOT peOk OR dv > cap.*?) \{', phase)[1]
    for good, dv, eta, reject in [(True, 45, 120, False), (True, .3, 120, False),
                                  (False, 45, 120, True), (True, 151, 120, True),
                                  (True, 45, 29, True)]:
        assert evaluate(rejection, peOk=good, dv=dv, cap=150,
                        nd=NS(TIME=1000 + eta), TIME=NS(SECONDS=1000)) == reject
    print('PASS: ordinary150m/s cap, opt-in live full-stack budget, unchanged50m/s reserve, invalid-value rejection,52–54km corridor, tiny burns and stale nodes')


def check_low_fuel_override():
    from check_burn_completion import execute
    from check_shape_minimum import Lex
    command = (ROOT/'cmd/returnmcc.ks').read_text()
    ready = body(command,'ready')
    code = body(command,'_cmdReturnmcc').replace('LOCAL FUNCTION ready {'+ready+'}', '')
    code = code.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.', 'settle().')
    def fixture():
        # bootApplyMissionConfig intentionally removes mission_type from state.
        # boot_lib's declarations can also reset the global at a command prompt;
        # resolve the saved Kerbin target through the real shared resolver.
        state = dict(phase='MCC',target='KERBIN',mission_id='kerbin_return',
                     launch_time=100, aerobrake_alarm='owned-alarm')
        settings = dict(MCC_RETURN_RESERVE_DV=50,MCC_RETURN_DV_CAP=150,
                        AEROBRAKE_AP_RESERVE_DV=10,AEROBRAKE_AP_BURN=1,
                        BURN_STAGE_LIMIT=1,DESCENT_CHUTES_TAG='descent_chutes')
        writes=[]
        def save(values):writes.append(dict(values));settings.update(values)
        env=dict(targetPe=52000,reserveDv=0,ABORT=False,HASNODE=False,WARP=7,
                 stateGet=state.get,RUNPATH=lambda *_:None,bootPreamble=lambda:None,
                 SHIP=NS(BODY=NS(NAME='Kerbin',ATM=NS(EXISTS=True,HEIGHT=70000)),
                         ALTITUDE=2e6,THRUST=0,DELTAV=NS(VACUUM=10.7),
                         CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
                 ETA=NS(PERIAPSIS=10000),LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),
                 MISSION_TYPE='',getTarget=lambda:state.get('target',''),missionOverrideUpdate=save)
        env['missionTypeDetect']=lambda:execute(body((ROOT/'lib/mission_type.ks').read_text(),
                                                    'missionTypeDetect'),env)
        env['ready']=lambda:execute(ready,env)
        env['settle']=lambda:None
        return env,state,settings,writes
    env,state,settings,writes=fixture();before=state.copy()
    assert execute(body(MCC,'_mccReturnBudget'),dict(env,**settings))==0
    execute(code,env)
    assert len(writes)==1 and state==before and env['WARP']==0
    assert execute(body(MCC,'_mccReturnBudget'),dict(env,**settings))==10.7
    assert all(settings[key]==52000 for key in ('CAPTURE_PE','REENTRY_PE','AEROBRAKE_PE'))
    assert settings['MCC_AEROBRAKE_SAFE_PE_MIN']==52000
    assert settings['MCC_AEROBRAKE_SAFE_PE_MAX']==52250
    assert settings['AEROBRAKE_AP_RESERVE_DV']==10 and settings['AEROBRAKE_AP_BURN']==1
    assert settings['BURN_STAGE_LIMIT']==1 and settings['DESCENT_CHUTES_TAG']=='descent_chutes'
    for pe,accepted in ((54000,False),(52250,True),(52050,True),(52000,True),(51999,False)):
        patch=NS(PERIAPSIS=pe)
        env.update(patch=patch,target=env['SHIP'].BODY,targetPe=52000,
                   _mccAerobrakeSafePeMin=lambda *_:settings['MCC_AEROBRAKE_SAFE_PE_MIN'],
                   _mccAerobrakeSafePeMax=lambda *_:settings['MCC_AEROBRAKE_SAFE_PE_MAX'])
        assert execute(body(MCC,'_mccAerobrakePatchSafe'),env)==accepted
    for fault in ('target','nan-target','reserve','nan-reserve','phase','mission','body','atmo',
                  'inside','late','nan-eta','node','interrupted','abort','thrust','nan-thrust',
                  'raw','pilot','changed-while-settling'):
        env,state,settings,writes=fixture();before=settings.copy()
        if fault=='target':env['targetPe']=51999
        if fault=='nan-target':env['targetPe']=math.nan
        if fault=='reserve':env['reserveDv']=-1
        if fault=='nan-reserve':env['reserveDv']=math.nan
        if fault=='phase':state['phase']='BPLANE'
        if fault=='mission':env['MISSION_TYPE']='other'
        if fault=='body':env['SHIP'].BODY.NAME='Mun'
        if fault=='atmo':env['SHIP'].BODY.ATM.EXISTS=False
        if fault=='inside':env['SHIP'].ALTITUDE=65000
        if fault=='late':env['ETA'].PERIAPSIS=599
        if fault=='nan-eta':env['ETA'].PERIAPSIS=math.nan
        if fault=='node':env['HASNODE']=True
        if fault=='interrupted':state.update(burn_pending='true',burn_started='true')
        if fault=='abort':env['ABORT']=True
        if fault=='thrust':env['SHIP'].THRUST=1
        if fault=='nan-thrust':env['SHIP'].THRUST=math.nan
        if fault=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='changed-while-settling':env['settle']=lambda:env.update(HASNODE=True)
        saved=state.copy();execute(code,env)
        assert not writes and settings==before and state==saved,fault
    print('PASS: reported10.7m/s fuel-reserve hold explicitly releases reserve, requests52km acquisition within existing52–54km safety bounds, preserves mission/alarms/staging/assist/repair reserve; unsafe or changed contexts cannot write')


def check_planner_fixture():
    # Independent two-body inbound trajectories, starting with the reported
    # 2200 km Pe. Exercise the existing Newton PE algorithm's scalar update
    # against analytic conics, not its own patched-conic prediction.
    source = body(TARGETING, 'newtonTarget')
    iterations = int(re.search(r'LOCAL maxIter IS (\d+)\.', source)[1])
    update = re.search(r'LOCAL correction IS (.*?)\.', source)[1]
    step = re.search(r'LOCAL maxStep IS CHOOSE .*? ELSE (.*?)\.\n', source)[1]
    mu, radius, wanted = 3.5316e12, 600000., 53000.
    cases=[(distance,radius+2200000,52e6,150,True) for distance in (35e6,45e6,47e6)]
    # The reported circular recovery requires441m/s and crosses stages.
    # Reproduce the old140m/s/1442km rejection, then solve the same conic
    # using the funded813.434-50 budget and unchanged Newton limits.
    for cap,converges in ((150,False),(813.434265136719-50,True)):
        cases.append((radius+2863314.35046328,radius+2863221.52404498,
                      radius+2863314.35046328,cap,converges))
    for distance,rp,ra,cap,converges in cases:
        semimajor = (rp + ra) / 2
        speed = math.sqrt(mu * (2 / distance - 1 / semimajor))
        transverse = math.sqrt(2 * mu * rp * ra / (rp + ra)) / distance

        def periapsis(prograde):
            velocity = speed + prograde
            angular_momentum = distance * transverse * velocity / speed
            energy = velocity**2 / 2 - mu / distance
            ecc = math.sqrt(1 + 2 * energy * angular_momentum**2 / mu**2)
            return angular_momentum**2 / (mu * (1 + ecc)) - radius

        prograde = 0.
        for _ in range(iterations):
            current = periapsis(prograde)
            err = wanted - current
            if abs(err) < 250:
                break
            sens = (periapsis(prograde + .1) - current) / .1
            correction = evaluate(update, err=err, sens=sens, damp=.5)
            limit = evaluate(step, err=err)
            old=prograde
            prograde += max(-limit, min(limit, correction))
            if abs(prograde)>cap:
                prograde=old
                break
            assert abs(prograde) <= cap
        assert (abs(periapsis(prograde) - wanted) < 250)==converges
        if not converges:
            assert abs(prograde)==140 and 1442400<periapsis(prograde)<1442600
        if cap>150:
            assert abs(abs(prograde)-441.0067697)<.1
    print('PASS: unchanged Newton scalar updates reproduce140m/s/1442km cap failure and converge on441m/s recovery with funded budget, plus three analytic2200km return fixtures')


def check_phase_flow():
    phase = body(MCC, '_mccReturn')
    # An interrupted node survives; only a measured safe orbit may advance.
    assert phase.index('maneuverBurnInterrupted()') < phase.index('REMOVE NEXTNODE')
    assert phase.count('nextPhase(') == 1
    safe = re.search(r'IF _mccAerobrakePatchSafe\(SHIP:ORBIT.*?\{(.*?)\}', phase, re.S)[1]
    assert 'nextPhase(xferSeq)' in safe
    assert 'UNTIL attempt > 3' in phase
    assert phase.index('IF attempt = 3') < phase.index('executeManeuver()')
    assert '"burn-failed-inspect-retained-node"' in phase
    assert '"flown-orbit-outside-corridor"' in phase
    assert 'MCC_MIN_DV' not in phase and 'CAPTURE_INC' not in phase
    hold = body(MCC, '_mccReturnHold')
    assert 'yieldToPrompt()' in hold and 'nextPhase(' not in hold
    assert 'REMOVE' not in hold and 'stateSet("phase"' not in hold
    dispatch = body(MCC, 'phaseMidCourse')
    assert dispatch.index('_mccReturn(target, targetPe)') < dispatch.index('LOCAL targetInc')
    guard = re.search(r'IF (SHIP:BODY:NAME = "Kerbin" AND SHIP:PERIAPSIS >= atmHeight)', AERO)[1]
    for name, pe, reroute in [('Kerbin', 2200000, True), ('Kerbin', 70000, True),
                               ('Kerbin', 53000, False), ('Duna', 2200000, False)]:
        assert evaluate(guard, SHIP=NS(BODY=NS(NAME=name), PERIAPSIS=pe),
                        atmHeight=70000) == reroute
    aero = body(AERO, 'phaseAerobrake')
    assert aero.index('stateSet("phase", "MCC")') < aero.index('_aerobrakeSetEntryAlarm()')
    assert 'no atmospheric approach and no MCC phase; holding' in aero
    command = (ROOT / 'cmd/setphase.ks').read_text()
    assert command.index('bootPreamble()') < command.index('stateGet(')
    assert 'missionOverrideClear' not in command and 'missionProfileBegin' not in command
    print('PASS: actual-orbit handoff, bounded retries, failure holds and saved AEROBRAKE recovery')


def recovery_fixture(inclination=60):
    mu,radius,rp,ra=3.5316e12,600000.,651096.,811500.
    ship=NS(BODY=NS(MU=mu),APOAPSIS=ra-radius,PERIAPSIS=rp-radius,DELTAV=NS(VACUUM=153),
            ORBIT=NS(BODY=NS(MU=mu,RADIUS=radius),SEMIMAJORAXIS=(rp+ra)/2,INCLINATION=inclination))
    env=ks.environment();nodes=[]
    def node(ut,radial,normal,prograde):
        # Independent Cartesian conic reconstruction at the apsis, rotated
        # into an inclined plane. No source Pe planner is used here.
        angle=math.radians(inclination)
        speed=math.sqrt(mu*(2/ra-2/(rp+ra)))
        pos=Vec((ra,0,0))
        vel=Vec((radial,(speed+prograde)*math.cos(angle)-normal*math.sin(angle),
                 (speed+prograde)*math.sin(angle)+normal*math.cos(angle)))
        h=Vec((0,-ra*vel[2],ra*vel[1]));energy=float(vel@vel)/2-mu/ra
        eccentricity=math.sqrt(1+2*energy*h.MAG**2/mu**2)
        pe=h.MAG**2/(mu*(1+eccentricity))
        orbit=NS(PERIAPSIS=pe-radius,APOAPSIS=-mu/energy-pe-radius,
                 INCLINATION=math.degrees(math.acos(h[2]/h.MAG)))
        return NS(TIME=ut,RADIALOUT=radial,NORMAL=normal,PROGRADE=prograde,
                  DELTAV=NS(MAG=math.sqrt(radial**2+normal**2+prograde**2)),ORBIT=orbit)
    env.update(SHIP=ship,STAGE=NS(DELTAV=NS(VACUUM=153)),ETA=NS(APOAPSIS=600),NODE=node,
               fixture_add=nodes.append,maneuverUiArchiveLog=lambda *_:None)
    env['_sar']=lambda *args:ks.call('_sar',env,*args)
    return env,nodes


def check_apo_recovery():
    for inclination in (0,6,60,120,179):
        env,nodes=recovery_fixture(inclination)
        nd=ks.call('planLowerPe',env,53000)
        assert nodes==[nd] and nd.TIME==600 and 1.5<nd.PROGRADE<1.7
        assert abs(nd.ORBIT.PERIAPSIS-53000)<1e-6 and abs(nd.ORBIT.APOAPSIS-211500)<1e-6
        assert abs(nd.ORBIT.INCLINATION-inclination)<1e-7
        assert ks.call('reentryPeNodeOk',env,nd,53000,52000,54000)
    print('PASS: actual shared apoapsis planner restores 51.096km Pe to 53km for 1.594m/s, preserving 211.5km Ap and five inclined planes')


def check_recovery_guards():
    for case in ('valid','late','excess-dv','no-fuel','pe','ap','plane','normal','radial','empty'):
        env,_=recovery_fixture();nd=ks.call('planLowerPe',env,53000)
        if case=='late':nd.TIME=29
        if case=='excess-dv':nd.DELTAV.MAG=20.1
        if case=='no-fuel':env['STAGE'].DELTAV.VACUUM=2
        if case=='pe':nd.ORBIT.PERIAPSIS=51999
        if case=='ap':nd.ORBIT.APOAPSIS+=101
        if case=='plane':nd.ORBIT.INCLINATION+=.011
        if case=='normal':nd.NORMAL=.01
        if case=='radial':nd.RADIALOUT=.01
        if case=='empty':nd.DELTAV.MAG=.01
        assert ks.call('reentryPeNodeOk',env,nd,53000,52000,54000)==(case=='valid'),case
    owner=body(RECOVERY,'_cmdReentrype')
    assert owner.index('SET WARP TO 0.')<owner.index('bootPreamble()')
    assert 'WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.' in owner
    assert owner.index('HASNODE OR maneuverBurnInterrupted()')<owner.index('restoreEntryPe(')
    shared=body(REPAIR,'restoreEntryPe')
    assert shared.index('reentryPeNodeOk(')<shared.index('executeManeuver()')
    after=shared[shared.index('LOCAL success IS executeManeuver()'):]
    assert 'nd:' not in after and 'REMOVE' not in after
    assert after.index('thrustCutoffOk()')<after.index('status=flown')
    assert 'stateSet' not in owner and 'missionOverride' not in owner
    print('PASS: recovery rejects stale/large/unfunded/off-corridor/plane-changing nodes; existing and failed burns are retained; no detached-node read follows execution')


if __name__ == '__main__':
    check_gates()
    check_low_fuel_override()
    check_planner_fixture()
    check_phase_flow()
    check_apo_recovery()
    check_recovery_guards()
