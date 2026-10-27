"""Source-driven boot, cleanup, phase-failure and compact-burn fixtures.

Uses the existing small source interpreter. This does not validate kOS
compilation, actual disk sizes, part APIs, or KSP flight dynamics.
"""
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import (ROOT, closure, dependency_tables, function_body,
                            command_entrypoint_errors, unscoped_returns)
from check_deorbit_geometry import Vec, evaluate


class KString(str):
    def __eq__(self, other):
        return isinstance(other, str) and self.casefold() == other.casefold()
    def __hash__(self): return hash(self.casefold())
    @property
    def LENGTH(self): return len(self)
    @property
    def TOUPPER(self): return KString(self.upper())
    def SUBSTRING(self, start, count=None):
        return KString(self[start:] if count is None else self[start:start+count])
    def CONTAINS(self, value): return value.lower() in self.lower()


class KList(list):
    @property
    def LENGTH(self): return len(self)
    def ADD(self, value): self.append(value)
    @property
    def COPY(self): return type(self)(self)


def run(source, env):
    try:
        ks.run(ks.parse(source), env)
    except ks.Returned as result:
        return result.value


def check_command_scopes():
    for source in ('RETURN.', 'IF NOT HASNODE { RETURN. }',
                   'UNTIL done { IF ABORT { RETURN FALSE. } }',
                   '@CLOBBERBUILTINS ON. IF ABORT { RETURN. }',
                   'LOCAL FUNCTION main { RETURN. } RETURN.'):
        assert unscoped_returns(source), source
    for source in ('LOCAL FUNCTION main { IF ABORT { RETURN FALSE. } } main().',
                   'FUNCTION outer { LOCAL FUNCTION inner { RETURN 1. } RETURN inner(). }',
                   'WHEN ABORT THEN { RETURN FALSE. }',
                   'ON AG1 { RETURN TRUE. }',
                   'LOCAL callback IS { RETURN TRUE. }.',
                   '// RETURN.\nPRINT "RETURN. { }".'):
        assert not unscoped_returns(source), source
    valid = '''@LAZYGLOBAL OFF.
        GLOBAL LIMIT IS 0.5.
        PARAMETER opts IS LEXICON().
        LOCAL FUNCTION main {
            LOCAL FUNCTION helper { RETURN 1. }
            IF ABORT { RETURN. }
            RUNPATH("1:/lib/boot_lib").
        }
        main().'''
    assert not command_entrypoint_errors(valid)
    for source in ('PRINT "old top-level command".',
                   valid.replace('main().', ''),
                   valid+'main().',
                   valid+'IF ABORT { PRINT "top-level logic". }',
                   valid.replace('main().', 'other().')):
        assert command_entrypoint_errors(source), source
    # The reported regression was inside the archive helper, beyond cmd/.
    helper = (ROOT / 'lib/burn_check.ks').read_text()
    assert not unscoped_returns(helper)
    assert len(unscoped_returns(function_body(helper, '_burnCheckMain'))) == 2
    print('PASS: scope guard rejects bare/nested file-level RETURN; command guard requires one local entry call; archive helper is covered')


def check_boot():
    boot = (ROOT / 'lib/boot_lib.ks').read_text()
    fallback = function_body(boot, 'bootPlannedMissionLibs').split('LOCAL sq IS', 1)[0]
    fallback = fallback.replace('DEFINED bootVehicleLibs', 'hasHook')
    for vehicle, sequence, linked, expected in (
            ('FJ1A', [], True, True), ('FSP1', [], False, True),
            ('Falcon', [], True, True), ('X_SHOT', [], True, False),
            ('FJ1A', ['PREFLIGHT'], True, False)):
        events = []
        libs = KList(['core', 'airplane'])
        env = dict(SEQUENCE=KList(sequence), LIST=lambda *xs: KList(xs), hasHook=True,
                   HOMECONNECTION=NS(ISCONNECTED=linked),
                   stateGet=lambda *_: KString(vehicle),
                   bootResolveScript=lambda *_: KString('craft/' + vehicle),
                   bootLibLoad=events.append, bootVehicleLibs=lambda: libs,
                   bootLibResolve=lambda roots: roots)
        result = run(fallback, env)
        assert (result == libs) == expected
        assert events == (['resume', 'craft/' + vehicle] if expected else [])
    # resume loads after the profile: it must not reinitialize mission config.
    resume = (ROOT / 'lib/resume.ks').read_text()
    assert not re.search(r'GLOBAL\s+(TARGET_|PAYLOADS|RENDEZVOUS_TARGET|ASTEROID_TARGET)\s+IS', resume)
    assert 'missionPayloadsFromState()' in function_body(resume, 'missionPayloads')
    payloads = function_body(boot, 'missionPayloadsFromState')
    for configured, saved, expected in (([], ['PROBE1'], ['PROBE1']),
                                        (['SCANSAT'], ['PROBE1'], ['SCANSAT']), ([], [], [])):
        assert run(payloads, dict(PAYLOADS=KList(configured), LIST=lambda: KList(),
                                  stateGet=lambda *_: KList(saved))) == expected
    assert not re.search(r'IF PAYLOADS:LENGTH > 0\s*\{\s*stateRemove\("payloads"\)',
                         function_body(boot, 'bootApplyMissionConfig'))
    assert 'GLOBAL BURN_BRIEF' not in (ROOT / 'lib/maneuver_ui.ks').read_text()
    load_source = function_body(boot, 'bootLibLoadList')
    for linked in (False, True):
        events, ran = [], []
        names = KList(map(KString, ('solar', 'xfer_plan', 'craft/Falcon')))
        env = dict(roots=names, BOOT_LIB_RAN=ran, HOMECONNECTION=NS(ISCONNECTED=linked),
                   bootLibResolve=lambda roots: roots, bootArchivePath=lambda name: '0:/' + name,
                   bootCorePath=lambda name: '1:/' + name, bootLibSync=lambda _: None,
                   bootLocalScriptPath=lambda name:'1:/'+name,
                   bootLibArchiveOnly=lambda name: name == 'xfer_plan', EXISTS=lambda _: True,
                   RUNONCEPATH=events.append, RUNPATH=events.append,
                   bootLibAddUnique=lambda dest, name: dest.append(name) if name not in dest else None)
        run(load_source, env)
        assert ran == (list(names) if linked else [names[0], names[2]])
        assert len(events) == len(ran)
    print('PASS: profile-less hooks, offline defaults, X_SHOT exclusion, late config preservation and actual-load registry')


def check_cleanup_and_links():
    cleanup = function_body((ROOT / 'lib/cleanup.ks').read_text(), '_cleanupShouldDeleteSource')
    for path, compiled, deleted in (
            ('1:/run/mission_overrides.ks', True, False),
            ('1:/missions/RO9/local.ks', True, False),
            ('1:/boot/boot.ks', True, False), ('1:/craft/FR3.ks', False, False),
            ('1:/lib/landing_coast.ks', False, False),
            ('1:/lib/solar.ks', True, True), ('1:/run/state.json', True, False)):
        result = run(cleanup, dict(path_=KString(path), name_=KString(path.rsplit('/', 1)[-1]),
                                   EXISTS=lambda _: compiled))
        assert result == deleted, path
    deps, phases, bands = dependency_tables((ROOT / 'lib/dependencies.ks').read_text())
    assert bands['payload_ops'] == ['targeted_deorbit', 'release_probe']
    assert bands['relay_ops'] == ['relay_ops']
    assert 'deorbit_burn' in closure(['deorbit_targeting'], deps)
    assert 'science' in closure(['scansat_ops'], deps)
    assert 'orbit' in closure(['molniya'], deps)
    assert 'maneuver' in closure(['inclination'], deps)
    assert 'landing_main' not in closure(['rover'], deps)
    assert 'deorbit_targeting' not in closure(phases['relay_ops'], deps)
    assert 'lib_bplane_math' not in function_body((ROOT / 'lib/boot_lib.ks').read_text(), 'bootArchiveOnlyLibs')
    assert 'LIST("science")' in function_body((ROOT / 'roles/lander_cpu.ks').read_text(), 'bootVehicleLibs')
    print('PASS: cleanup preserves executable/override sources; payload pair stays resident; relay/rover shedding; flight dependencies')


def check_phase_failures():
    for filename, handler, operation in (
            ('payload_ops', 'phaseTargetedDeorbit', 'targetedDeorbit'),
            ('payload_landing', 'phaseLand', 'landExecute')):
        source = function_body((ROOT / f'lib/{filename}.ks').read_text(), handler)
        for success in (False, True):
            events = []
            env = dict(targetResolveDeorbitTarget=lambda: dict(FOUND=False),
                       landingApplyMissionConfig=lambda: None,
                       _redirectOrbitalLandingPhase=lambda _: False, _payloadSeq=lambda: [], launchSeq=[],
                       yieldToPrompt=lambda: events.append('hold'), nextPhase=lambda _: events.append('advance'),
                       mLogError=lambda _: None)
            env[operation] = lambda: success
            run(source, env)
            assert events == (['advance'] if success else ['hold']), (handler, success, events)
    guidance = function_body((ROOT / 'lib/landing_main.ks').read_text(), '_landingGuidanceTick')
    env = dict(ctx=dict(STATE='COAST'), ABORT=False, landingAbortFlag=True, _landingEnsureStateTrack=lambda _: None)
    run(guidance, env)  # Missing track must not invoke any guidance delegate.
    rover = (ROOT / 'craft/ROVER.ks').read_text()
    main = function_body(rover, 'main')
    assert 'SET launchSeq TO seq.' in main and 'SET xferSeq TO seq.' in main
    defaults = (ROOT / 'lib/rover.ks').read_text()
    assert len(re.findall(r'GLOBAL ROVER_\w+ IS', defaults)) == 20
    assert 'GLOBAL SCI_LOG_INTERVAL IS 60.' in (ROOT / 'lib/science.ks').read_text()
    assert 'DEFINED planeActive AND planeActive' in (ROOT / 'lib/observe.ks').read_text()
    print('PASS: failed deorbit/landing cannot advance; missing track exits before delegation; rover/science/telemetry config')


def check_return_setup_binding():
    source=function_body((ROOT/'lib/dependencies.ks').read_text(),'dependencyBindPhase')
    source=re.sub(r'DEFINED (\w+)',r'fixture_defined("\1")',source)
    source=re.sub(r'(\w+)@',r'fixture_delegate("\1")',source)
    declared=set(re.findall(r'GLOBAL FUNCTION (\w+)',(ROOT/'lib/return_setup.ks').read_text()))
    for phase,handler in (('RETURN_SETUP','phaseReturnSetup'),
                          ('SURFACE_RETURN_SETUP','phaseSurfaceReturnSetup')):
        for loaded,active_phase in ((True,phase),(False,phase),(False,'LAND_ASSIST')):
            warnings=[]
            # Cross-compiled functions occupy $name*, not scalar $name.
            # DEFINED must probe the provider's explicit scalar capability.
            symbols={name+'*' for name in declared} if loaded else set()
            variables={'RETURN_SETUP_LOADED'} if loaded else set()
            bindings={}
            def delegate(name):
                assert name+'*' in symbols,('undefined handler dereferenced',name)
                return name
            env=dict(phaseMap=bindings,phaseName=phase,fixture_defined=lambda name:name in variables,RETURN_SETUP_LOADED=loaded,
                     stateGet=lambda key,default='':active_phase,mLogError=warnings.append,
                     fixture_delegate=delegate,
                     phaseMapSet=lambda mapping,key,value:mapping.update({key:value}))
            # This check needs the real warning branch; the general run()
            # helper suppresses logging for physics-only cases.
            checked=source.replace('mLogError(', 'capture_error(')
            env['capture_error']=warnings.append
            run(checked,env)
            assert (handler in symbols)==False
            assert bindings==({phase:handler} if loaded else {})
            assert bool(warnings)==(not loaded and active_phase==phase)
    machine=function_body((ROOT/'lib/phases.ks').read_text(),'runPhases')
    assert machine.index('dependencyBindPhase(phaseMap, phase)')<machine.index('PHASE HANDLER MISSING:')
    assert 'yieldToPrompt().' in machine[machine.index('PHASE HANDLER MISSING:'):]
    assert 'GLOBAL RETURN_SETUP_LOADED IS TRUE.' in (ROOT/'lib/return_setup.ks').read_text()
    assert 'DEFINED phaseReturnSetup' not in source and 'DEFINED phaseSurfaceReturnSetup' not in source
    print('PASS: return binding uses an actually loaded scalar capability rather than bare cross-compiled function names; loaded providers bind both delegates and missing providers retain the explicit hold')


def check_ascent_return_cache():
    source=function_body((ROOT/'lib/mission_type.ks').read_text(),'missionTypeConditionalRoots')
    class Sequence(list):
        CONTAINS=list.__contains__
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    baseline=closure(['core']+[lib for phase in bands['launch'] for lib in phases[phase]],deps)
    assert 'return_setup' not in baseline
    # The actual conditional planner is used by both installed boot planning
    # and rocketVehicleLibsForBand; test generated surface-return intent.
    for band,sequence,wanted in (
            ('LAUNCH',['PRELAUNCH','LAUNCH','PARK','RETURN_SETUP'],True),
            ('LAUNCH',['PRELAUNCH','LAUNCH','PARK','DONE'],False),
            ('PRELAUNCH',['PRELAUNCH','LAUNCH','PARK','RETURN_SETUP'],True),
            ('SHAPE',['PRELAUNCH','LAUNCH','PARK','SHAPE','RETURN_SETUP'],True),
            ('SHAPE',['CAPTURE','SHAPE','SCIENCE_OPS','LAND_DEORBIT'],False),
            ('RETURN_SETUP',['PRELAUNCH','LAUNCH','PARK','RETURN_SETUP'],False)):
        env=dict(bandKey=band,SEQUENCE=Sequence(sequence),LIST=lambda *xs:KList(xs))
        extra=run(source,env)
        assert ('return_setup' in extra)==wanted
        if wanted:
            keep=baseline|closure(extra,deps)
            assert {'return_setup','aerobrake_config'}<=keep
            assert 'maneuver' not in keep and 'maneuver_plan' not in keep
    boot=(ROOT/'lib/boot_lib.ks').read_text()
    rocket=(ROOT/'lib/rocket_craft.ks').read_text()
    assert 'missionTypeConditionalRoots(band)' in function_body(boot,'bootPlannedMissionLibs')
    assert 'missionTypeConditionalRoots(band)' in function_body(rocket,'rocketVehicleLibsForBand')
    print('PASS: connected surface-ascent planning caches return_setup and its config before cleanup; ordinary launch/other bands retain their original closure and the maneuver executor stays out of LAUNCH')


def check_compact_burn():
    source = function_body((ROOT / 'lib/deorbit_burn.ks').read_text(), 'executeDeorbitNode')
    source = re.sub(r'WAIT UNTIL (.*?)\.(?=\s*\n)', r'UNTIL \1 { WAIT 0.02. }', source, flags=re.S)
    source = re.sub(r'UNLOCK (\w+)\.', r'fixture_unlock("\1").', source)
    source = source.replace('REMOVE nd.', 'fixture_remove(nd).')
    for scenario in ('normal', 'cutoff-fault', 'frozen', 'weak-thrust', 'abort', 'flameout', 'reversal', 'no-engine', 'expired', 'off-vector', 'unlit-site'):
        class AttachedNode:
            # Match kOS Node.GetBurnVector/Remove: both suffix aliases throw
            # after REMOVE invalidates this wrapper's NodeRef.
            attached = True
            TIME = -1 if scenario == 'expired' else 200
            residual = NS(MAG=10.)
            vector = Vec((1, 0, 0))
            @property
            def DELTAV(self):
                if not self.attached: raise RuntimeError('Must attach node first')
                return self.residual
            @property
            def BURNVECTOR(self):
                if not self.attached: raise RuntimeError('Must attach node first')
                return self.vector
            @BURNVECTOR.setter
            def BURNVECTOR(self, value): self.vector = value
        node = AttachedNode()
        ship = NS(MASS=10., THRUST=0., AVAILABLETHRUST=0. if scenario == 'no-engine' else 100.,
                  BODY=NS(NAME='Mun'),
                  CONTROL=NS(PILOTMAINTHROTTLE=0.), FACING=NS(FOREVECTOR=Vec((1, 0, 0))))
        removed, commands, elapsed = [], [], [0.]
        markers, callbacks, history = {}, {}, []
        def remove(nd):
            removed.append(nd)
            nd.attached = False
            # Include an already queued callback even after UNLOCK, or an
            # owner trigger unknown to a different compiled cleanup library.
            for expression in history: evaluate(expression, env)
        env = dict(nd=node, TIME=NS(SECONDS=0.), SHIP=ship, ABORT=False, throttle=0.,
                   CONFIG=NS(IPU=150), LANDING_MIN_IPU=2000,
                   KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),
                   ROUND=round, VANG=lambda *_: 30 if scenario == 'off-vector' else 0,
                   vesselLandingPrepareRoles=lambda:True,
                   landingLightNodeAllowed=lambda *_: scenario != 'unlit-site',
                   stateSet=lambda key, value: markers.update({key: value}),
                   stateRemove=lambda key: markers.pop(key, None),
                   vesselNeedsStage=lambda: ship.AVAILABLETHRUST <= 0,
                   vesselStageForLanding=lambda _: None,
                   maneuverEnsureBurnAlarm=lambda *_: '', coastAutoWarp=lambda *_: None,
                   enterSolarCoast=lambda *_:1,solarCoastCanWarp=lambda *_:True,
                   coastHealthCheck=lambda *_:True,
                   trySolarHoldTick=lambda ref,*_:ref,HASNODE=True,
                   DELETEALARM=lambda _: None, fixture_remove=remove,
                   fixture_unlock=lambda name: callbacks.pop(name, None))

        def lock(statement):
            name, expression = re.fullmatch(r'LOCK (\w+) TO (.*)', statement, re.S).groups()
            callbacks[name] = expression
            history.append(expression)
            if name == 'THROTTLE':
                env['throttle'] = evaluate(expression, env)
                commands.append(env['throttle'])

        def wait(dt):
            for name, expression in callbacks.items():
                value = evaluate(expression, env)
                if name == 'THROTTLE': env['throttle'] = value
            env['TIME'].SECONDS += dt
            ship.THRUST = ship.AVAILABLETHRUST * env['throttle'] * (.01 if scenario == 'weak-thrust' else 1)
            if env['throttle'] <= 0:
                return
            elapsed[0] += dt
            if scenario == 'abort' and elapsed[0] > .3: env['ABORT'] = True
            if scenario == 'flameout' and elapsed[0] > .3: ship.AVAILABLETHRUST = 0
            if scenario == 'reversal' and elapsed[0] > .3: node.BURNVECTOR = Vec((-1, 0, 0))
            if scenario not in ('frozen', 'abort', 'flameout', 'reversal'):
                node.DELTAV.MAG -= ship.THRUST / ship.MASS * dt
            assert env['TIME'].SECONDS < 300

        def cleanup():
            # Physical cutoff can override throttle without removing the
            # original file's steering trigger.
            callbacks['THROTTLE'] = '0'
            env.update(throttle=0.)
            ship.CONTROL.PILOTMAINTHROTTLE=0
            wait(.02)
            return scenario!='cutoff-fault'
        env.update(fixture_lock=lock, fixture_wait=wait,
                   vesselLandingCleanup=cleanup)
        result = run(source, env)
        assert result == (scenario == 'normal'), scenario
        assert bool(removed) == result and env['throttle'] == 0, scenario
        assert env['CONFIG'].IPU==150 and 'burn_prior_ipu' not in markers
        if scenario in ('no-engine', 'expired', 'off-vector', 'unlit-site'): assert not any(commands)
        burned = elapsed[0] > 0
        assert ('deorbit_burn_started' in markers) == (burned and not result), scenario
        if scenario == 'frozen': assert elapsed[0] < 1.1  # Old timeout allowed ~10 s of full thrust.
    print('PASS: compact burn completion and failures; deferred callbacks survive removed nodes without reading suffixes; failed nodes retained')
    # A blocked publishing loop cannot leave the cached burn command on.
    throttle=re.search(r'LOCK THROTTLE TO (throttleCmd.*?)\.(?=\s*\n)',source,re.S)[1]
    for age,expected in ((0,.7),(.3,.7),(.49,.35),(.5,0),(10,0)):
        value=evaluate(throttle,dict(throttleCmd=.7,commandUntil=100.5,TIME=NS(SECONDS=100+age)))
        assert abs(value-expected)<1e-10,(age,value)
    print('PASS: cached compact-burn command expires without publisher progress; temporary CPU budget restored on all burn results')


def check_cutoff_handoffs():
    phase=function_body((ROOT/'lib/phases.ks').read_text(),'nextPhase')
    state=dict(phase='LAND_DEORBIT')
    # No sequence access, phase mutation, or phase-log I/O after a cutoff
    # fault has asked the dispatcher to yield.
    assert run(phase,dict(seq=[],phaseShouldYield=True,stateGet=state.get))=='LAND_DEORBIT'
    source=function_body((ROOT/'lib/landing_main.ks').read_text(),'_landingSetState')
    prefix=source[:source.index('_landingStateLog(')]
    for okay in (False,True):
        events=[]
        ctx=dict(STATE='BRAKING_BURN',TARGET_THROTTLE=.35)
        env=dict(ctx=ctx,nextState='COAST',reason='test',landingAbortFlag=False,
                 _landingSetThrottle=lambda c,x: c.update(TARGET_THROTTLE=x),
                 thrustCutoffOk=lambda release: (events.append(('verify',release)) or okay),
                 fixture_lock=lambda s: events.append('rebind'))
        run(prefix,env)
        assert ctx['TARGET_THROTTLE']==0
        assert events==([('verify',False),'rebind'] if okay else [('verify',False)])
        assert env['landingAbortFlag']==(not okay)
    # All direct burn families must declare a resident path to the shared
    # routine. This also protects the offline, storage-limited deorbit band.
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for name in ('maneuver','deorbit_burn','ascent','maneuver_rendezvous',
                 'landing_main','aerobrake','landing_atmo','hop','ssto','suborbit','payload_release',
                 'scansat_ops','descent'):
        assert 'thrust_cutoff' in closure([name],deps),name
    for name in ('aerobrake','landing_atmo','hop','ssto','suborbit','payload_release','scansat_ops','descent'):
        source=(ROOT/'lib'/f'{name}.ks').read_text()
        assert not re.search(r'LOCK THROTTLE TO 0\.\s*(?:WAIT [\d.]+\.\s*)?UNLOCK THROTTLE\.',source),name
    watchdog=function_body((ROOT/'lib/suborbit.ks').read_text(),'_armDescentWatchdog')
    assert watchdog.index('thrustCutoff(FALSE)')<watchdog.index('stateSet("phase", "DESCENT")')
    assert 'IF NOT thrustCutoffOk()' not in watchdog
    abort=function_body((ROOT/'lib/launch.ks').read_text(),'launchAbort')
    assert abort.index('ABORT ON.')<abort.index('thrustCutoff(FALSE)')<abort.index('REBOOT.')
    print('PASS: cutoff fault blocks phase advancement; landing verifies zero before rebinding; direct burn families load shared cutoff offline')


def check_rendezvous():
    source = (ROOT / 'lib/maneuver_rendezvous.ks').read_text()
    arrival = function_body(source, '_matchConverged')
    predicate = re.search(r'RETURN (.*?)\.\s*$', arrival, re.S)[1]
    for distance, speed, abort, expected in ((150, .1, False, True), (151, .1, False, False),
                                            (100, 15, False, False), (100, .1, True, False)):
        assert evaluate(predicate, dict(separation=distance, relativeSpeed=speed,
                                        finalDist=150, ABORT=abort)) == expected
    burn = function_body(source, '_matchBurnRel').replace('SAS OFF.', 'SET SAS TO FALSE.')
    for scenario in ('normal', 'abort', 'no-engine', 'off-vector', 'already-matched'):
        ship = NS(MASS=10., AVAILABLETHRUST=0. if scenario in ('no-engine', 'already-matched') else 100.,
                  VELOCITY=NS(ORBIT=Vec((0 if scenario == 'already-matched' else 10., 0, 0))),
                  FACING=NS(FOREVECTOR=Vec((1, 0, 0))))
        env = dict(ves=NS(VELOCITY=NS(ORBIT=Vec((0, 0, 0)))), SHIP=ship,
                   desiredVec=Vec((0, 0, 0)), TIME=NS(SECONDS=0.), ABORT=False,
                   VANG=lambda *_: 30 if scenario == 'off-vector' else 0)
        direction = [Vec((0, 0, 0))]

        def lock(statement):
            if statement.startswith('LOCK STEERING TO '): direction[0] = env['errVec'].NORMALIZED

        def wait(dt):
            env['TIME'].SECONDS += dt
            ship.VELOCITY.ORBIT += direction[0] * env['throttleCmd'] * ship.AVAILABLETHRUST / ship.MASS * dt
            if scenario == 'abort' and env['TIME'].SECONDS > .3: env['ABORT'] = True

        env.update(fixture_lock=lock, fixture_wait=wait,
                   _matchStopThrottle=lambda: (env.update(throttleCmd=0.) or True))
        assert run(burn, env) == (scenario in ('normal', 'already-matched')), scenario
        assert env['throttleCmd'] == 0
    stop = function_body(source, '_matchStopThrottle')
    assert 'thrustCutoffOk()' in stop and 'RETURN stopped.' in stop
    phase = function_body(source, 'phaseMatch')
    assert phase.index('_matchConverged(') < phase.index('nextPhase(')
    print('PASS: rendezvous requires distance AND relative speed; timeout/abort/no thrust hold; already-matched needs no engine')


if __name__ == '__main__':
    check_command_scopes()
    check_boot()
    check_cleanup_and_links()
    check_phase_failures()
    check_return_setup_binding()
    check_ascent_return_cache()
    check_compact_burn()
    check_cutoff_handoffs()
    check_rendezvous()
