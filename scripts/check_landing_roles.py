"""Tagged hardware roles against source staging; not native KSP part APIs."""
import re
from types import SimpleNamespace as NS

from check_landing_stage_reserve import serial_fixture
from check_landing_guidance import call
from check_runtime_contracts import KList,run
from check_codebase import ROOT,function_body,mask,closure,dependency_tables

SOURCE=(ROOT/'lib/landing_roles.ks').read_text()


def fixture():
    env,ctx,transfer,lander,returning,events=serial_fixture()
    def separator(stage):
        return NS(STAGE=stage,ISDECOUPLED=False,STAGED=True,
                  HASMODULE=lambda module:module=='ModuleDecouple')
    return_part=separator(1);release_part=separator(2)
    tagged={'return_decoupler':KList([return_part]),'lander_decoupler':KList([release_part])}
    env.update(CORE=NS(PART=NS(DECOUPLEDIN=-1)),LANDING_STAGE_LIMIT=0)
    env['SHIP'].PARTSTAGGED=lambda name:tagged.get(name,KList())
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:call(name,env,*args)
    return env,ctx,transfer,lander,returning,events,tagged,return_part,release_part


def check_tagged_staging():
    env,ctx,transfer,lander,returning,events,_,ret,release=fixture()
    assert env['vesselLandingPrepareRoles']()
    assert env['vesselLandingStageFloor']()==2 and env['LANDING_STAGE_LIMIT']==0
    assert call('vesselLandingReserveAcc',env)==7.5
    transfer.FLAMEOUT=True
    for i in range(20):
        env['TIME'].SECONDS=i*.1
        call('vesselStageForLanding',env,ctx)
    assert events==[2] and lander.IGNITION and not returning.IGNITION
    lander.FLAMEOUT=True
    for i in range(20,40):
        env['TIME'].SECONDS=i*.1
        call('vesselStageForLanding',env,ctx)
    assert events==[2] and not returning.IGNITION
    # Reboot recomputes role intent from the physical tags, without an
    # override/state file or archive connection.
    env,ctx,transfer,lander,returning,events,_,ret,release=fixture()
    ret.STAGE=4;release.STAGE=5
    lander.STAGE=5;lander.DECOUPLEDIN=4
    returning.STAGE=4
    transfer.STAGE=6;transfer.DECOUPLEDIN=5
    env['STAGE'].NUMBER=6
    assert env['vesselLandingPrepareRoles']() and env['vesselLandingStageFloor']()==5
    env['LANDING_STAGE_LIMIT']=2
    assert env['vesselLandingStageFloor']()==5 # Numeric override cannot weaken a tag.
    ret.STAGE=3
    assert env['vesselLandingStageFloor']()==4 # Live part stage, not a saved number.
    print('PASS: tagged 3/2/1 stack reserves1 with no numeric override, preserves wet return mass and blocks return ignition after lander exhaustion; new boot/renumbered6/5/4 hardware derives its own floor and cannot be weakened by a lower manual setting')


def check_legacy_and_released_carrier():
    for kind in ('untagged','release-only','return-only','released-carrier','disabled'):
        env,_,_,_,_,_,tags,ret,release=fixture()
        if kind=='untagged':tags.clear()
        if kind=='release-only':tags.pop('return_decoupler')
        if kind=='return-only':tags.pop('lander_decoupler')
        if kind=='released-carrier':release.ISDECOUPLED=True
        if kind=='disabled':env['LANDING_RETURN_DECOUPLER_TAG']='none'
        assert env['vesselLandingPrepareRoles'](),kind
        assert env['vesselLandingStageFloor']()==(2 if kind in ('return-only','released-carrier') else 0)
    env,_,_,_,_,_,tags,ret,release=fixture()
    env['LANDING_RETURN_DECOUPLER_TAG']='ascent_separator'
    env['LANDING_RELEASE_DECOUPLER_TAG']='payload_separator'
    tags.clear();tags.update(ascent_separator=KList([ret]),payload_separator=KList([release]))
    assert env['vesselLandingPrepareRoles']() and env['vesselLandingStageFloor']()==2
    print('PASS: untagged/manual-floor craft retain legacy policy; release-only, spent carrier separators, return-only and configured tag names work without firing any hardware')


def check_invalid_roles():
    for kind in ('duplicate-return','duplicate-release','wrong-part','unstaged','negative-stage','past','spent-return',
                 'core-discarded','swapped','same-part','no-lander','no-return','return-active','return-misstaged','manual-excludes-lander'):
        env,ctx,transfer,lander,returning,events,tags,ret,release=fixture()
        if kind=='duplicate-return':tags['return_decoupler'].append(ret)
        if kind=='duplicate-release':tags['lander_decoupler'].append(release)
        if kind=='wrong-part':ret.HASMODULE=lambda _:False
        if kind=='unstaged':ret.STAGED=False
        if kind=='negative-stage':ret.STAGE=-1
        if kind=='past':env['STAGE'].NUMBER=1
        if kind=='spent-return':ret.ISDECOUPLED=True
        if kind=='core-discarded':env['CORE'].PART.DECOUPLEDIN=1
        if kind=='swapped':release.STAGE=0
        if kind=='same-part':tags['lander_decoupler']=KList([ret])
        if kind=='no-lander':lander.POSSIBLETHRUST=0
        if kind=='no-return':returning.POSSIBLETHRUST=0
        if kind=='return-active':returning.IGNITION=True
        if kind=='return-misstaged':returning.STAGE=3
        if kind=='manual-excludes-lander':env['LANDING_STAGE_LIMIT']=3
        assert not env['vesselLandingPrepareRoles'](),kind
        assert env['vesselLandingStageFloor']()>env['STAGE'].NUMBER
        assert call('vesselLandingReserveAcc',env)==.001
        # Even an already-selected engine at its activation slot cannot
        # bypass invalid roles after thrust is lost. Keep this independent
        # of the ordinary usable-current-engine early return.
        transfer.FLAMEOUT=True
        env['STAGE'].NUMBER=2
        ctx.update(STAGE_ENGINE=2,STAGE_ACTIVATED=False)
        call('vesselStageForLanding',env,ctx)
        assert not events and not lander.IGNITION
        assert returning.IGNITION==(kind=='return-active')
        assert not call('vesselLandingStageEvent',env,ctx,2) and not events
    print('PASS: ambiguous/wrong/spent/misstaged/CPU-losing role boundaries refuse new staging, including cached activation, while an urgent conservative future-thrust budget prevents treating a transfer engine as inexhaustible')


def check_entrypoints_and_committed_recovery():
    deorbit=(ROOT/'lib/landing_deorbit.ks').read_text()
    phase=function_body(deorbit,'phaseLandDeorbit')
    for committed in (False,True):
        events=[]
        env=dict(landingApplyMissionConfig=lambda:None,ABORT=False,
                 vesselLandingPrepareRoles=lambda:events.append('roles') or False,
                 SHIP=NS(STATUS='SUB_ORBITAL' if committed else 'ORBITING'),
                 LANDING_SKIP_TARGET_SEARCH=0,landingImpactAcceptableForAssist=lambda:True,
                 _advanceAfterLandDeorbit=lambda:events.append('advance'),yieldToPrompt=lambda:events.append('hold'))
        run(phase,env)
        assert events==(['roles','advance'] if committed else ['roles','hold'])
    main=function_body((ROOT/'lib/landing_main.ks').read_text(),'landExecute')
    assert main.index('vesselLandingPrepareRoles()')<main.index('_landingCacheTick(ctx)')
    before_main=main[:main.index('LOCAL priorArchiveDeferral')]
    assert 'RETURN' not in mask(before_main) and 'yieldToPrompt' not in before_main
    solver=function_body((ROOT/'lib/deorbit_targeting.ks').read_text(),'targetedDeorbitAt')
    assert solver.index('vesselLandingPrepareRoles()')<solver.index('SET _deorbitEvaluations TO 0.')
    burn=function_body((ROOT/'lib/deorbit_burn.ks').read_text(),'executeDeorbitNode')
    assert burn.index('vesselLandingPrepareRoles()')<burn.index('vesselStageForLanding(ctx)')
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'landing_roles' in closure(['landing_main'],deps)
    assert 'landing_roles' in closure(['landing_deorbit','deorbit_targeting','deorbit_burn'],deps)
    assert 'landing_main' not in closure(['landing_deorbit','deorbit_targeting','deorbit_burn'],deps)
    clean=mask(SOURCE)
    assert not re.search(r'(?<!:)\b(?:STAGE|ADD|REMOVE|LOCK|UNLOCK|REBOOT)\s*\.',clean)
    assert not re.search(r'\b(?:DOEVENT|ACTIVATE|stateSet|missionOverrideUpdate)\b',clean)
    print('PASS: orbital phase/planner/executor validate roles before planning or staging; committed suborbital recovery advances to guidance and bad role metadata does not abort landExecute; role metadata loads offline with existing bands and never fires separation/engines or saves derived stages')


if __name__=='__main__':
    check_tagged_staging()
    check_legacy_and_released_carrier()
    check_invalid_roles()
    check_entrypoints_and_committed_recovery()
