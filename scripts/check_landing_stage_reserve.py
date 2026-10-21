"""Exercise three-stage landing reservation; no KSP runtime or flight model."""
import math
import re
from types import SimpleNamespace as NS

from check_landing_braking import hardware_fixture,call
from check_landing_stage_brake import hardware
from check_codebase import ROOT,function_body,mask,command_entrypoint_errors
from check_runtime_contracts import run


def serial_fixture():
    env,ctx,transfer,lander,events=hardware_fixture()
    transfer.STAGE=3;transfer.DECOUPLEDIN=2
    lander.DECOUPLEDIN=1
    returning=NS(STAGE=1,DECOUPLEDIN=-1,IGNITION=False,FLAMEOUT=False,
                 THROTTLELOCK=False,POSSIBLETHRUST=8,AVAILABLETHRUST=0)
    env['SHIP'].ENGINES.append(returning)
    env['STAGE'].NUMBER=3
    env['SHIP'].PARTS=[NS(MASS=3,DECOUPLEDIN=2),NS(MASS=1,DECOUPLEDIN=1),NS(MASS=1,DECOUPLEDIN=-1)]
    env['LANDING_STAGE_LIMIT']=2
    def stage():
        env['STAGE'].NUMBER-=1
        events.append(env['STAGE'].NUMBER)
        if env['STAGE'].NUMBER==2:
            env['SHIP'].ENGINES.remove(transfer)
            env['SHIP'].PARTS.pop(0)
            env['SHIP'].MASS=2
    env['stage_event']=stage
    return env,ctx,transfer,lander,returning,events


def check_landing_boundary():
    env,ctx,transfer,lander,returning,events=serial_fixture()
    assert call('vesselLandingReserveAcc',env)==7.5 # Return stage wet mass carried.
    call('vesselStageForLanding',env,ctx)
    assert events==[] # Use the remaining transfer propellant first.
    transfer.FLAMEOUT=True
    for tick in range(20):
        env['TIME'].SECONDS=tick*.1
        call('vesselStageForLanding',env,ctx)
    assert events==[2] and lander.IGNITION and not returning.IGNITION
    lander.FLAMEOUT=True
    env['LANDING_STAGE_LIMIT']=0
    assert call('vesselLandingNextEngineStage',env)==1 # Reproduce unreserved risk.
    env['LANDING_STAGE_LIMIT']=2
    for tick in range(20,50):
        env['TIME'].SECONDS=tick*.1
        call('vesselStageForLanding',env,ctx)
    assert events==[2] and env['STAGE'].NUMBER==2 and not returning.IGNITION
    assert call('vesselLandingReserveAcc',env)==0
    ascent=(ROOT/'lib/ascent.ks').read_text()
    assert 'LANDING_STAGE_LIMIT' not in mask(ascent)
    setup=(ROOT/'lib/return_setup.ks').read_text()
    assert 'missionOverrideClear().' in function_body(setup,'_beginLegProfile')
    assert '_beginLegProfile("surface_return")' in function_body(setup,'phaseSurfaceReturnSetup')
    launch=(ROOT/'lib/launch.ks').read_text()
    assert 'GLOBAL ASCENT_STAGED IS FALSE.' in launch
    print('PASS: actual 3->2 landing handoff carries return wet mass, consumes transfer fuel first and cannot select/ignite stage1 after stage2 exhaustion; surface-return setup clears the landing-only override and ascent retains its own staging')


def check_reserved_fuel_exclusion():
    env,_,transfer,lander,held=hardware()
    # Shift original two-stage hardware to match the reported 3/2/1 stack.
    env['STAGE'].NUMBER=3
    transfer.STAGE=3;transfer.DECOUPLEDIN=2
    lander.STAGE=2;lander.DECOUPLEDIN=1
    env['SHIP'].PARTS[0].DECOUPLEDIN=2
    returning=NS(STAGE=1,DECOUPLEDIN=-1,IGNITION=False,FLAMEOUT=False,
                 POSSIBLETHRUST=5,AVAILABLETHRUST=0,THROTTLELOCK=False)
    env['SHIP'].ENGINES.append(returning)
    env['LANDING_STAGE_LIMIT']=0
    assert call('vesselLandingBrakeStageDv',env)==0 # Existing multi-stage rejection.
    env['LANDING_STAGE_LIMIT']=2
    assert abs(call('vesselLandingBrakeStageDv',env)-313)<1e-8
    # Arbitrarily more retained return propellant cannot increase transfer credit.
    env['SHIP'].PARTS[-1].RESOURCES[0].AMOUNT=1e12
    assert abs(call('vesselLandingBrakeStageDv',env)-313)<1e-8
    # A lower engine that is actually running is still a parallel-thrust rejection.
    returning.IGNITION=True;returning.AVAILABLETHRUST=5
    assert call('vesselLandingBrakeStageDv',env)==0
    print('PASS: explicit reservation permits the bounded transfer-only credit with an inactive return engine; retained fuel never supplies credit and active parallel propulsion still refuses the model')


def check_configuration_command():
    text=(ROOT/'cmd/landingstages.ks').read_text()
    assert not command_entrypoint_errors(text)
    clean=mask(text)
    assert not re.search(r'\b(?:STAGE|ADD|REMOVE|LOCK|UNLOCK|REBOOT)\s*\.',clean)
    assert not re.search(r'\b(?:stateSet|stateRemove|missionOverrideClear|executeManeuver)\s*\(',clean)
    source=function_body(text,'_cmdLandingstages')
    source=source.replace('RUNPATH("1:/lib/boot_lib").','').replace('bootPreamble().','')
    source=source.replace('bootLibLoad("vessel_hardware").','')
    source=re.sub(r'PRINT "[^"\n]*"[^\n]*?\.(?=\n)', '', source)
    for kind in ('valid','missing','fraction','past','core-lost','abort','thrust','raw','pilot','solid','flameout','reserved-active'):
        env,_,_,lander,returning,events=serial_fixture()
        saved=dict(SEQUENCE=['LAND_ASSIST','SURFACE_RETURN_SETUP'],RETURN_PE=53000)
        env.update(lastLandingStage=2,CORE=NS(PART=NS(DECOUPLEDIN=-1)),FLOOR=math.floor,
                   missionOverrideUpdate=lambda values:saved.update(values),LANDING_STAGE_LIMIT=0)
        if kind=='missing':env['lastLandingStage']=-1
        if kind=='fraction':env['lastLandingStage']=1.5
        if kind=='past':env['STAGE'].NUMBER=1
        if kind=='core-lost':env['CORE'].PART.DECOUPLEDIN=2
        if kind=='abort':env['ABORT']=True
        if kind=='thrust':env['SHIP'].THRUST=1
        if kind=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if kind=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if kind=='solid':lander.THROTTLELOCK=True
        if kind=='flameout':lander.FLAMEOUT=True
        if kind=='reserved-active':returning.IGNITION=True
        run(source,env)
        assert ('LANDING_STAGE_LIMIT' in saved)==(kind=='valid'),kind
        assert env['LANDING_STAGE_LIMIT']==(2 if kind=='valid' else 0)
        assert saved['SEQUENCE']==['LAND_ASSIST','SURFACE_RETURN_SETUP'] and saved['RETURN_PE']==53000
        assert not events
    print('PASS: per-flight command saves only the verified landing stage floor, preserves return/mission intent and rejects absent/invalid/consumed stages, a lost core, Abort, physical/raw/pilot thrust and enabled reserved engines')


if __name__=='__main__':
    check_landing_boundary()
    check_reserved_fuel_exclusion()
    check_configuration_command()
