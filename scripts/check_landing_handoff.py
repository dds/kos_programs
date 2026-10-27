"""Landing band/track loading and radio policy; not native KSP validation."""
from types import SimpleNamespace as NS

from check_boot_install import fixture as disk_fixture, Items
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_runtime_contracts import KList, run


def check_no_blackout_admission_gate():
    source=(ROOT/'lib/deorbit_burn.ks').read_text()
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'landingHandoffReady' not in source
    assert 'bootLibEnsureCached' not in source
    assert 'landing_handoff' not in closure(phases['land_deorbit'],deps)
    assert not (ROOT/'lib/landing_handoff.ks').exists()
    # Loading remains a band transition after burn completion. All existing
    # trajectory, lighting, staging, attitude and cutoff checks remain.
    for guard in ('landingLightNodeAllowed(', 'vesselLandingPrepareRoles()',
                  'VANG(SHIP:FACING:FOREVECTOR', 'vesselLandingCleanup()',
                  'beforeBurn:CALL('):
        assert guard in source,guard
    advance=function_body((ROOT/'lib/landing_deorbit.ks').read_text(),'_advanceAfterLandDeorbit')
    assert 'bootLibBandForPhase' in advance and 'REBOOT.' in advance
    conditional=function_body((ROOT/'lib/mission_type.ks').read_text(),'missionTypeConditionalRoots')
    env=dict(bandKey='LANDING',SEQUENCE=Items(['LAND_ASSIST','SURFACE_RETURN_SETUP']),
             LIST=lambda *xs:Items(xs))
    roots=run(conditional,env)
    assert {'landing_coast','landing_brake','return_setup'}<=set(roots)
    assert 'landing_main' not in closure(phases['land_deorbit'],deps)
    print('PASS: operator-approved deorbit has no offline-cache admission; physical guards/post-burn reboot remain, and LANDING still loads both tracks and its conditional return provider')


def check_cached_track_retention():
    source=function_body((ROOT/'lib/landing_main.ks').read_text(),'_landingEnsureStateTrack')
    assert 'DELETEPATH' not in source
    env,files,events,state=disk_fixture(linked=False)
    files['1:/lib/landing_brake.ksm']=('ksm','SET fixtureBrakeLoaded TO TRUE.')
    env.update(landingActiveTrack='',landingLoadedTracks=Items(),landingAbortFlag=False,
               stateName='BRAKING_BURN')
    # The script resolver expects native string suffixes, supplied by Text.
    from check_boot_install import Text
    env['_landingTrackForState']=lambda _:Text('landing_brake')
    env['run_body'](source)
    assert env['fixtureBrakeLoaded'] and env['landingActiveTrack']=='landing_brake'
    assert '1:/lib/landing_brake.ksm' in files
    assert not any(e[0]=='compile' for e in events)
    print('PASS: existing cached tracks continue to load offline and remain available for reboots; removing pre-burn admission does not disable caching')


def check_shared_radio_policy():
    from check_landing_light import environment
    env=environment(kerbin_longitude=180)
    env.update(LANDING_REQUIRE_KERBIN=0,LANDING_LIGHT_MODE='ANY',
               LANDING_DIRECT_KERBIN_BODIES=KList(['Mun','Minmus']))
    env['SHIP'].BODY.ORBIT=NS(ECCENTRICITY=.1)
    for name in ('Mun','Minmus'):
        env['SHIP'].BODY.NAME=name
        assert env['landingRequireKerbin']()==1 and env['landingLightActive']()
        assert not env['landingLightAt'](0,0,env['TIME'].SECONDS)['OK']
    env['LANDING_RELAY_BODIES']=KList(['Minmus'])
    env['LANDING_REQUIRE_KERBIN']=1 # Old economy profiles migrate globally.
    assert env['landingRequireKerbin']()==0
    assert env['landingLightAt'](0,0,env['TIME'].SECONDS)['OK']
    env['LANDING_RADIO_MODE']='DIRECT'
    assert env['landingRequireKerbin']()==1
    env['LANDING_RADIO_MODE']='OFFLINE'
    assert env['landingRequireKerbin']()==0
    env['LANDING_RADIO_MODE']='TYPO'
    assert env['landingLightActive']() and not env['landingLightAt'](0,0,env['TIME'].SECONDS)['OK']
    # Committed-diversion policy can still waive radio explicitly. This
    # does not change any physical landing admission limit.
    env['LANDING_RADIO_MODE']='DIRECT'
    assert env['landingLightAt'](0,0,env['TIME'].SECONDS,0,0)['OK']
    print('PASS: shared Mun/Minmus AUTO policy rejects far-side sites despite legacy0; per-body relays waive direct view across profiles, DIRECT/OFFLINE overrides are explicit and invalid mode holds; committed diversion waiver remains')


if __name__=='__main__':
    check_no_blackout_admission_gate()
    check_cached_track_retention()
    check_shared_radio_policy()
