"""Execute parking-controller handoff source; not native MechJeb/KSP."""
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask

SOURCE=(ROOT/'lib/launch.ks').read_text()
ks.SOURCES+='\n'+SOURCE


def fixture(mode='normal'):
    events=[]
    # Match the installed bridge: there is no top-level NODE suffix.
    mj=NS(AVAILABLE=mode!='no-addon',ASCENT=NS(ENABLED=True))
    env=dict(ADDONS=NS(MJ=mj),TIME=NS(SECONDS=0),ABORT=False,HASNODE=True,
             SHIP=NS(PERIAPSIS=72700,APOAPSIS=78000),phaseShouldYield=False,
             _launchHasAtmosphere=lambda:mode!='airless',
             _isParkingOrbitStable=lambda:env['SHIP'].PERIAPSIS>70200,
             yieldToPrompt=lambda:env.update(phaseShouldYield=True))
    def wait(seconds):
        env['TIME'].SECONDS+=seconds
        events.append(('wait',seconds))
        if mode=='abort':env['ABORT']=True
        if mode not in ('timeout','abort') and env['TIME'].SECONDS>=2:
            mj.ASCENT.ENABLED=False
            # Emulate MJ removing its own completed circularization node.
            if mode!='foreign-node':env['HASNODE']=False
            env['SHIP'].PERIAPSIS=69900 if mode=='bad-orbit' else 77700
    def cutoff():
        if mode not in ('no-addon','airless'):
            assert not mj.ASCENT.ENABLED
        events.append(('cutoff',))
        if mode=='cutoff':env['phaseShouldYield']=True;return False
        return True
    env.update(fixture_wait=wait,thrustCutoffOk=cutoff)
    return env,events


def check_controller_completion():
    for mode in ('normal','foreign-node','no-addon','airless'):
        env,events=fixture(mode)
        assert ks.call('_parkingControllerHandoff',env)
        assert not env['phaseShouldYield'] and events[-1]==('cutoff',)
        if mode in ('normal','foreign-node'):assert env['TIME'].SECONDS>=2
        else:assert env['TIME'].SECONDS==0
        assert env['HASNODE']==(mode!='normal')
    source=function_body(SOURCE,'phaseParking')
    assert source.index('_parkingControllerHandoff()')<source.index('nextPhase(launchSeq)')
    assert 'REMOVE' not in mask(function_body(SOURCE,'_parkingControllerHandoff'))
    print('PASS: bridge without NODE waits for MJ ascent completion, verifies cutoff before advancing, preserves foreign nodes, and leaves native airless/no-addon insertion independent')


def check_controller_failure():
    for mode in ('timeout','abort','cutoff','bad-orbit'):
        env,events=fixture(mode)
        assert not ks.call('_parkingControllerHandoff',env) and env['phaseShouldYield'],mode
        assert events[-1]==('cutoff',)
        if mode in ('timeout','abort'):
            assert env['HASNODE'] and not env['ADDONS'].MJ.ASCENT.ENABLED
        if mode=='timeout':assert 120<=env['TIME'].SECONDS<120.2
    print('PASS: timeout/Abort stop native ascent before cutoff and preserve nodes; failed cutoff or degraded parking orbit cannot hand off to XING')


if __name__=='__main__':
    check_controller_completion()
    check_controller_failure()
