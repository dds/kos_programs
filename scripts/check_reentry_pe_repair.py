"""Shared manual/automatic entry repair and resident apoapsis wake, not KSP."""
import math
import re
from types import SimpleNamespace as NS
from functools import lru_cache

from check_codebase import ROOT, function_body as uncached_function_body
function_body=lru_cache(maxsize=32)(uncached_function_body)
from check_aerobrake_reentry import execute, Map
from check_return_mcc import recovery_fixture
import check_landing_guidance as ks
from check_deorbit_geometry import Vec

REPAIR=(ROOT/'lib/reentry_pe.ks').read_text()
AERO=(ROOT/'lib/aerobrake.ks').read_text()
MANEUVER=(ROOT/'lib/maneuver.ks').read_text()


class Text(str):
    def CONTAINS(self, value):return value.lower() in self.lower()


def source(name, text=REPAIR):
    return re.sub(r'WAIT UNTIL [^.]+\.', 'settle().', function_body(text,name))


def fixture():
    env,nodes=recovery_fixture();events=[]
    ship=env['SHIP'];ship.BODY=ship.ORBIT.BODY
    ship.BODY.NAME='Kerbin';ship.BODY.ATM=NS(EXISTS=True,HEIGHT=70000)
    ship.BODY.POSITION=Vec((0,0,0));ship.POSITION=Vec((750000,0,0))
    ship.VELOCITY=NS(ORBIT=Vec((10,2000,0)))
    ship.ALTITUDE=150000;ship.ORBIT.ECCENTRICITY=.1;ship.ORBIT.HASNEXTPATCH=False
    ship.STATUS='SUB_ORBITAL';ship.DELTAV.VACUUM=10
    ship.THRUST=0;ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    saved={'phase':'AEROBRAKE','mission_id':'return','launch_time':1234}
    env.update(stateGet=lambda key,default='':saved.get(key,default),
               stateGetNum=lambda key,default=0:saved.get(key,default),
               stateSet=lambda key,value:saved.__setitem__(key,value),
               stateRemove=lambda key:saved.pop(key,None),saved=saved)
    env['STAGE'].DELTAV.VACUUM=10
    env.update(targetPe=53000,peLow=52000,peHigh=54000,atmHeight=70000,
               _fs=lambda value,places:str(round(value,places)),
               HASNODE=False,ABORT=False,WARP=0,phaseShouldYield=False,
               BURN_TRIM_ABS_COMPLETE_DV=.05,BURN_TRIM_COMPLETE_MAX_DV=.05,
               LEXICON=lambda *xs:Map(zip(xs[::2],xs[1::2])),VDOT=lambda a,b:float(a@b),
               maneuverBurnInterrupted=lambda:execute(function_body(MANEUVER,'maneuverBurnInterrupted'),dict(env)),
               settle=lambda:None,
               thrustCutoffOk=lambda:events.append('cutoff') or True,
               reentryPeNodeOk=lambda nd,pe,lo,hi:execute(function_body(REPAIR,'reentryPeNodeOk'),
                    dict(env,nd=nd,desiredPe=pe,peLow=lo,peHigh=hi)))
    env['reentryPeTrimLimit']=lambda pe:execute(function_body(REPAIR,'reentryPeTrimLimit'),dict(env,desiredPe=pe))
    env['reentryPeRecover']=lambda pe,lo,hi,legacy=False:execute(function_body(REPAIR,'reentryPeRecover'),
        dict(env,targetPe=pe,peLow=lo,peHigh=hi,allowLegacy=legacy))
    def remove(nd):
        nodes.remove(nd);env['HASNODE']=False
    env['remove']=remove
    env['_ren']=lambda ntm:execute(re.sub(r'WAIT [^.]+\.', '',function_body(MANEUVER,'_ren')).replace('REMOVE NEXTNODE.','remove(NEXTNODE).'),dict(env,ntm=ntm))
    env['_cpb']=lambda reason:execute(function_body(MANEUVER,'_cpb'),dict(env,reason=reason))
    env['maneuverAcceptHandoff']=lambda:execute(function_body(MANEUVER,'maneuverAcceptHandoff'),dict(env))
    def add(nd):nodes.append(nd);env['HASNODE']=True;env['NEXTNODE']=nd
    env['fixture_add']=add
    def plan(pe):return ks.call('planLowerPe',env,pe)
    env['planLowerPe']=plan
    def burn():
        assert env['BURN_TRIM_ABS_COMPLETE_DV']==env['BURN_TRIM_COMPLETE_MAX_DV']==.05
        events.append('burn');nd=nodes[-1]
        ship.PERIAPSIS=nd.ORBIT.PERIAPSIS;ship.APOAPSIS=nd.ORBIT.APOAPSIS
        ship.ORBIT.INCLINATION=nd.ORBIT.INCLINATION
        ship.DELTAV.VACUUM-=nd.DELTAV.MAG;env['STAGE'].DELTAV.VACUUM-=nd.DELTAV.MAG
        env['HASNODE']=False
        return True
    env['executeManeuver']=burn
    from check_aerobrake_assist import entry_helpers
    entry_helpers(env)
    return env,nodes,events


def run(env):
    body=source('restoreEntryPe').replace('REMOVE nd.','remove(nd).')
    env.setdefault('remove',lambda nd:env.__setitem__('HASNODE',False))
    return execute(body,env)


def check_shared_repair():
    env,nodes,events=fixture()
    result=run(env)
    assert result['OK'] and result['BURNED'] and result['REASON']=='restored'
    assert events==['cutoff','burn','cutoff'] and len(nodes)==1
    assert abs(nodes[0].DELTAV.MAG-1.594)<.001
    assert abs(env['SHIP'].PERIAPSIS-53000)<1e-6
    assert abs(env['SHIP'].APOAPSIS-211500)<1e-6
    assert abs(env['SHIP'].ORBIT.INCLINATION-60)<1e-6
    assert 8<env['STAGE'].DELTAV.VACUUM<10 # This is what the reserve is for.
    assert env['BURN_TRIM_ABS_COMPLETE_DV']==env['BURN_TRIM_COMPLETE_MAX_DV']==.05
    for fault in ('abort','node','interrupted','inside','inbound','hyperbolic','patch','late',
                  'fuel','node-pe','node-plane','node-ap','node-normal','node-dv','burn','flown','cutoff'):
        env,nodes,events=fixture()
        if fault=='abort':env['ABORT']=True
        if fault=='node':env['HASNODE']=True
        if fault=='interrupted':env['maneuverBurnInterrupted']=lambda:True
        if fault=='inside':env['SHIP'].ALTITUDE=60000
        if fault=='inbound':env['SHIP'].VELOCITY.ORBIT=-env['SHIP'].VELOCITY.ORBIT
        if fault=='hyperbolic':env['SHIP'].ORBIT.ECCENTRICITY=1.1
        if fault=='patch':env['SHIP'].ORBIT.HASNEXTPATCH=True
        if fault=='late':env['ETA'].APOAPSIS=29
        if fault=='fuel':env['STAGE'].DELTAV.VACUUM=.4
        plan=env['planLowerPe']
        def bad_plan(pe):
            nd=plan(pe)
            if fault=='node-pe':nd.ORBIT.PERIAPSIS=51000
            if fault=='node-plane':nd.ORBIT.INCLINATION+=.1
            if fault=='node-ap':nd.ORBIT.APOAPSIS+=200
            if fault=='node-normal':nd.NORMAL=.01
            if fault=='node-dv':nd.DELTAV.MAG=21
            return nd
        env['planLowerPe']=bad_plan
        if fault=='burn':env['executeManeuver']=lambda:False
        if fault=='flown':
            def inaccurate():env['SHIP'].PERIAPSIS=51000;env['HASNODE']=False;return True
            env['executeManeuver']=inaccurate
        if fault=='cutoff':env['thrustCutoffOk']=lambda:False
        result=run(env)
        assert not result['OK'],fault
        assert env['BURN_TRIM_ABS_COMPLETE_DV']==env['BURN_TRIM_COMPLETE_MAX_DV']==.05,fault
        if fault=='burn':assert env['HASNODE'] and len(nodes)==1
        if fault.startswith('node-'):assert not env['HASNODE']
    assert 'restoreEntryPe(targetPe,52000,54000)' in (ROOT/'cmd/reentrype.ks').read_text()
    print('PASS: actual shared repair spends1.594m/s from the protected10 to restore53km while preserving Ap/plane, restores precision settings, and rejects17 timing/frame/node/fuel/abort/cutoff/flown-orbit hazards without deleting failed burns')



def check_precision_budget():
    env,_,_=fixture();mu=env['SHIP'].BODY.MU;radius=env['SHIP'].BODY.RADIUS
    for ap in (94717,211500,386276,2863334,52e6):
        env['SHIP'].APOAPSIS=ap
        limit=env['reentryPeTrimLimit'](53000)
        assert 0.001<=limit<=0.05
        ra,rp=radius+ap,radius+53000
        speed=math.sqrt(2*mu*rp/(ra*(ra+rp)))
        def pe(velocity):
            energy=velocity**2/2-mu/ra
            eccentricity=abs(1-ra*velocity**2/mu)
            return (ra*velocity)**2/(mu*(1+eccentricity))-radius
        assert abs(pe(speed)-53000)<1e-6
        derivative=(pe(speed+1e-5)-pe(speed-1e-5))/2e-5
        expected=speed*(ra+rp)**2/mu
        assert abs(derivative/expected-1)<1e-6
        assert max(abs(pe(speed+limit)-53000),abs(pe(speed-limit)-53000))<63
    env['BURN_TRIM_ABS_COMPLETE_DV']=.002
    assert env['reentryPeTrimLimit'](53000)<=.002
    print('PASS: actual cutoff sensitivity matches independent conic differences over94.7km..52Mm apoapsides, budgets<63m Pe error and preserves stricter operator precision')


def check_reconciliation():
    modes=('deleted','retained','legacy','legacy-retained','no-permission','wrong-phase',
           'wrong-body','wrong-abort','large-residual','nan-residual','infinite-residual',
           'negative-residual','wrong-node','large-live-node','inside','patch','unbound',
           'low-pe','high-pe','off-target','thrust','raw-throttle','pilot-throttle','abort',
           'forced','not-stopped','stale-command','wrong-intent-body','wrong-intent-phase',
           'wrong-intent-node','wrong-intent-mission','wrong-intent-launch','wrong-intent-target',
           'changed-ap','changed-plane','malformed-intent','cutoff','large-burn','missing-marker')
    for mode in modes:
        env,nodes,events=fixture();ship=env['SHIP'];saved=env['saved']
        nd=env['planLowerPe'](53000)
        saved['reentry_pe_intent']=Map(mission='return',launch=1234,phase='AEROBRAKE',
            body='Kerbin',nodeUt=nd.TIME,targetPe=53000,peLow=52000,peHigh=54000,
            startAp=ship.APOAPSIS,startInc=ship.ORBIT.INCLINATION)
        ship.PERIAPSIS=53000
        nd.DELTAV.MAG=.008181178
        saved.update(burn_pending='true',burn_started='true',burn_phase='AEROBRAKE',
            burn_body='Kerbin',burn_dv=8.648012,burn_node_time=nd.TIME,
            burn_abort_reason='residual-outside-tolerance',burn_abort_residual=.008181178,
            last_burn_report=Text('reason=live-thrust-axis-trim cutoffFault=residual-outside-tolerance shutdownAttempted=False thrustStopped=True'))
        if mode not in ('retained','legacy-retained','wrong-node','large-live-node'):
            env['remove'](nd)
        if mode.startswith('legacy') or mode=='no-permission':saved.pop('reentry_pe_intent')
        if mode=='wrong-phase':saved['phase']='MCC'
        if mode=='wrong-body':saved['burn_body']='Duna'
        if mode=='wrong-abort':saved['burn_abort_reason']='thrust-after-cutoff'
        if mode=='large-residual':saved['burn_abort_residual']=.051
        if mode=='nan-residual':saved['burn_abort_residual']=math.nan
        if mode=='infinite-residual':saved['burn_abort_residual']=math.inf
        if mode=='negative-residual':saved['burn_abort_residual']=-.001
        if mode=='wrong-node':nd.TIME+=100
        if mode=='large-live-node':nd.DELTAV.MAG=.1
        if mode=='inside':ship.ALTITUDE=60000
        if mode=='patch':ship.ORBIT.HASNEXTPATCH=True
        if mode=='unbound':ship.ORBIT.ECCENTRICITY=1.1
        if mode=='low-pe':ship.PERIAPSIS=51999
        if mode=='high-pe':ship.PERIAPSIS=54001
        if mode=='off-target':ship.PERIAPSIS=53501
        if mode=='thrust':ship.THRUST=.01
        if mode=='raw-throttle':ship.CONTROL.MAINTHROTTLE=.01
        if mode=='pilot-throttle':ship.CONTROL.PILOTMAINTHROTTLE=.01
        if mode=='abort':env['ABORT']=True
        if mode=='forced':saved['last_burn_report']=Text(saved['last_burn_report'].replace('shutdownAttempted=False','shutdownAttempted=True'))
        if mode=='not-stopped':saved['last_burn_report']=Text(saved['last_burn_report'].replace('thrustStopped=True','thrustStopped=False'))
        if mode=='stale-command':saved['last_burn_report']=Text(saved['last_burn_report'].replace('live-thrust-axis-trim','live-command-stale'))
        for key,field,value in (('body','body','Mun'),('phase','phase','MCC'),('node','nodeUt',900),
                                ('mission','mission','other'),('launch','launch',77),('target','targetPe',53500)):
            if mode=='wrong-intent-'+key:saved['reentry_pe_intent'][field]=value
        if mode=='changed-ap':ship.APOAPSIS+=101
        if mode=='changed-plane':ship.ORBIT.INCLINATION+=.11
        if mode=='malformed-intent':saved['reentry_pe_intent']=Map(mission='return')
        if mode=='cutoff':env['thrustCutoffOk']=lambda:False
        if mode=='large-burn':saved['burn_dv']=21
        if mode=='missing-marker':saved.pop('burn_started')
        before=dict(saved);node_before=list(nodes)
        accepted=env['reentryPeRecover'](53000,52000,54000,mode.startswith('legacy'))
        assert bool(accepted)==(mode in ('deleted','retained','legacy','legacy-retained')),mode
        if accepted:
            assert not any(key.startswith('burn_') for key in saved),mode
            assert saved['last_burn_report']==before['last_burn_report']
            assert not nodes and not env['HASNODE']
            assert saved['reentry_pe_reconciled']['legacy']==mode.startswith('legacy')
        else:
            assert saved==before and nodes==node_before,mode
    # Real repair owner: emulate the recorded executor residual abort, then
    # run its actual goal verification and actual shared handoff cleanup.
    env,nodes,events=fixture()
    def residual_abort():
        nd=nodes[-1];env['SHIP'].PERIAPSIS=nd.ORBIT.PERIAPSIS
        nd.DELTAV.MAG=.008181178
        env['saved'].update(burn_pending='true',burn_started='true',burn_phase='AEROBRAKE',
            burn_body='Kerbin',burn_dv=8.648012,burn_node_time=nd.TIME,
            burn_abort_reason='residual-outside-tolerance',burn_abort_residual=.008181178,
            last_burn_report=Text('reason=live-thrust-axis-trim cutoffFault=residual-outside-tolerance shutdownAttempted=False thrustStopped=True'))
        return False
    env['executeManeuver']=residual_abort
    result=run(env)
    assert result['OK'] and result['BURNED'] and not env['HASNODE']
    assert 'burn_pending' not in env['saved'] and 'reentry_pe_intent' not in env['saved']
    assert 'last_burn_report' in env['saved']
    # Boot path also reconciles the saved intent before the pending-node
    # guard; it neither plans another burn nor waits for another apoapsis.
    env,nodes,events=fixture();nd=env['planLowerPe'](53000)
    env['saved']['reentry_pe_intent']=Map(mission='return',launch=1234,phase='AEROBRAKE',
        body='Kerbin',nodeUt=nd.TIME,targetPe=53000,peLow=52000,peHigh=54000,
        startAp=env['SHIP'].APOAPSIS,startInc=env['SHIP'].ORBIT.INCLINATION)
    env['saved'].update(burn_pending='true',burn_started='true',burn_phase='AEROBRAKE',
        burn_body='Kerbin',burn_dv=8.648012,burn_node_time=nd.TIME,
        burn_abort_reason='residual-outside-tolerance',burn_abort_residual=.008181178,
        last_burn_report=Text('reason=live-thrust-axis-trim cutoffFault=residual-outside-tolerance shutdownAttempted=False thrustStopped=True'))
    env['SHIP'].PERIAPSIS=53000;nd.DELTAV.MAG=.008181178
    env['AEROBRAKE_PE_TARGETING']=1
    assert execute(function_body(AERO,'_aerobrakeRestorePe'),env)
    assert not env['HASNODE'] and 'burn_pending' not in env['saved']
    command=(ROOT/'cmd/reentryresume.ks').read_text()
    assert 'LOCAL FUNCTION _cmdReentryresume' in command and command.rstrip().endswith('_cmdReentryresume().')
    assert 'reentryPeRecover(targetPe,52000,54000,TRUE)' in command
    assert 'executeManeuver(' not in command and 'stateRemove(' not in command
    print('PASS: actual intent-backed/native-orbit reconciliation and shared burn-marker/node cleanup handle recorded0.008181178 abort and deleted/retained legacy nodes;35 invalid/unsafe/foreign cases retain all evidence')

def check_apoapsis_wait():
    for mode in ('normal','no-kac','abort','body','node','stage','no-fuel','inbound','inside','small','final','disabled','rejected',
                 'retained-good-pe','interrupted-inbound'):
        env,nodes,events=fixture();env['TIME'].SECONDS=1000
        env.update(AEROBRAKE_PE_TARGETING=1,kacEnsureAlarm=lambda *args:events.append(('alarm',args[1])) or ('' if mode=='no-kac' else 'repair'),
                   DELETEALARM=lambda key:events.append(('delete',key)),
                   yieldToPrompt=lambda:events.append('held'))
        def coast(wake,alarm):
            assert events[0]==('alarm',1420)
            assert alarm==('' if mode=='no-kac' else 'repair')
            events.append(('solar',wake));env['TIME'].SECONDS=wake;env['ETA'].APOAPSIS=180
            if mode=='abort':env['ABORT']=True
            if mode=='body':env['SHIP'].BODY=NS(NAME='Mun')
            if mode=='node':env['HASNODE']=True
        def stage(*args):
            events.append(('stage-audit',args[1],args[2]))
            assert args[1]<env['SHIP'].PERIAPSIS<args[2]
            env['STAGE'].DELTAV.VACUUM=20
            return True
        def repair(*args):
            events.append(('repair',*args))
            return Map(OK=mode not in ('no-fuel','rejected'),REASON='insufficient-fuel' if mode=='no-fuel' else 'native-node-rejected')
        env.update(_aerobrakeSolarWait=coast,aerobrakeApStageCoast=stage,restoreEntryPe=repair)
        # Existing interruption cases have no owned repair to reconcile.
        env['reentryPeRecover']=lambda *args:False
        if mode=='stage':env['STAGE'].DELTAV.VACUUM=0
        if mode=='inbound':env['SHIP'].VELOCITY.ORBIT=-env['SHIP'].VELOCITY.ORBIT
        if mode=='inside':env['SHIP'].ALTITUDE=60000
        if mode=='small':env['SHIP'].PERIAPSIS=52900
        if mode=='final':env['SHIP'].APOAPSIS=65000
        if mode=='disabled':env['AEROBRAKE_PE_TARGETING']=0
        if mode=='retained-good-pe':env['HASNODE']=True;env['SHIP'].PERIAPSIS=53000
        if mode=='interrupted-inbound':
            env['maneuverBurnInterrupted']=lambda:True
            env['SHIP'].VELOCITY.ORBIT=-env['SHIP'].VELOCITY.ORBIT
        result=execute(function_body(AERO,'_aerobrakeRestorePe'),env)
        assert bool(result)==(mode not in ('abort','body','node','rejected','retained-good-pe','interrupted-inbound')),mode
        if mode in ('inbound','inside','small','final','disabled'):assert not events,mode
        elif mode in ('abort','body','node'):assert not any(e[0]=='repair' for e in events if isinstance(e,tuple))
        elif mode in ('retained-good-pe','interrupted-inbound'):assert events==['held']
        else:assert ('repair',53000,52000,54000) in events
        if mode=='stage':assert any(isinstance(e,tuple) and e[0]=='stage-audit' for e in events)
    phase=function_body(AERO,'phaseAerobrake')
    assert phase.count('_aerobrakeRestorePe(atmHeight,assistPe,peLow,peHigh)')==2
    assert phase.index('_aerobrakeRestorePe(')<phase.index('_aerobrakeSolarWait(')
    loop=phase[phase.index('UNTIL SHIP:STATUS'):]
    assert loop.index('_aerobrakeRestorePe(')<loop.index('aerobrakeApAssist(')
    print('PASS: reboot/post-pass repair installs its apoapsis KAC wake before solar with clock fallback, revalidates interruptions, can audit an empty-stage successor, and preserves passive descent when fuel is gone or no further outside pass remains')


def check_drifted_pe_stage_audit():
    from check_aerobrake_staging import fixture as staged_fixture
    assist=(ROOT/'lib/aerobrake_assist.ks').read_text()
    for hazard in ('none','cpu','chutes','still-fueled'):
        env,events,saved,tags,engines,tanks,set_fuel=staged_fixture()
        env['SHIP'].PERIAPSIS=51096
        assert not env['aerobrakeApStageCoast'](70000,52000,54000)
        if hazard=='cpu':env['CORE'].PART.DECOUPLEDIN=2
        if hazard=='chutes':tags.pop('descent_chutes')
        if hazard=='still-fueled':set_fuel(0,10)
        current=env['SHIP'].PERIAPSIS
        result=env['aerobrakeApStageCoast'](70000,min(52000,current-1000),max(54000,current+1000))
        assert bool(result)==(hazard=='none'),hazard
        assert any(e[0]=='stage' for e in events)==(hazard=='none'),hazard
        if hazard=='none':
            # The wider COAST envelope exposed a funded, retained engine.
            # It must not leak into the unchanged actual burn admission.
            env['SHIP'].VELOCITY=NS(ORBIT=NS(MAG=3000),SURFACE=NS(MAG=2800))
            env.update(atmHeight=70000,peLow=52000,peHigh=54000,targetPe=53000)
            plan=execute(function_body(assist,'_aeroApPlan'),env)
            assert not plan['OK'] and plan['REASON']=='not-coasting-or-outside-entry-corridor'
    print('PASS: real audited stager can expose repair fuel at51.096km Pe, still rejects CPU/chute/fueled-stage hazards; the real powered-entry planner continues to reject that Pe until repaired')


if __name__=='__main__':
    check_precision_budget()
    check_reconciliation()
    check_shared_repair()
    check_apoapsis_wait()
    check_drifted_pe_stage_audit()
