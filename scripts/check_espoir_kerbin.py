"""Kerbin profiles plus real site/entry guards with synthetic physics; not KSP."""
import math
from types import SimpleNamespace as NS
import check_entry_landing as entry
import check_landing_review as review
import check_atmo_deorbit as atmo
from check_espoir_fleet import profile,native,Map,Items
from check_codebase import ROOT,dependency_tables,closure


def kerbin(ship):
    ship.BODY.NAME='Kerbin';ship.BODY.RADIUS=600000;ship.BODY.MU=3.5316e12
    ship.BODY.ATM.HEIGHT=70000;ship.BODY.ROTATIONPERIOD=21600
    ship.PERIAPSIS=ship.APOAPSIS=100000
    ship.ORBIT=NS(HASNEXTPATCH=False,ECCENTRICITY=0,INCLINATION=90,
        PERIOD=2*math.pi*math.sqrt(700000**3/ship.BODY.MU))


def check_profiles_and_local_launch():
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    prelaunch=(ROOT/'lib/prelaunch.ks').read_text()
    for name,terminal in (('kerbin_orbital_surveyor','SCANSAT_OPS'),('kerbin_lander','LANDING_REVIEW')):
        cfg=profile(name)
        assert cfg['MISSION_ID']==name and cfg['TARGET_']=='KERBIN' and cfg['MISSION_TYPE']=='kerbin_orbit'
        assert cfg['PARKING_ALT']==cfg['TARGET_PE']==cfg['TARGET_AP']==cfg['SHAPE_PE']==cfg['SHAPE_AP']==100000
        assert cfg['LAUNCH_INCLINATION']==cfg['TARGET_INCLINATION']==cfg['SHAPE_INC']==90
        assert cfg['LAUNCH_PLANE_MODE']=='' and cfg['CAPTURE_LAN']==-1
        assert cfg['COAST_AUTO_WARP']==0 and cfg['SHAPE_MIN_PE']>=80000
        assert cfg['SEQUENCE'].index('SHAPE')<cfg['SEQUENCE'].index(terminal)
        assert not set(cfg['SEQUENCE']) & {'XING','BPLANE','REFINE_BPLANE','CAPTURE','ASSIST','IKE_SETUP'}
        assert len(cfg['SEQUENCE'])==len(set(cfg['SEQUENCE']))
        for phase in cfg['SEQUENCE']:assert phase.lower() in phases and closure(phases[phase.lower()],deps)
        events=[];env=dict(cfg,confirmLaunch=lambda:True,_prelaunchClearPlanState=lambda:None,fixture_log=lambda:None,
            _prelaunchRdvTarget=lambda:'',nextPhase=lambda seq:events.append('LAUNCH'),launchSeq=cfg['SEQUENCE'],
            stateGet=lambda key,default='':'PRELAUNCH' if key=='phase' else default)
        env['_prelaunchNextPhaseIs']=lambda phase:entry.call(prelaunch,'_prelaunchNextPhaseIs',env,phase)
        def forbidden(*_):raise AssertionError('local mission tried a body-orbit/interplanetary launch setup')
        env.update(_prelaunchToBodyOrbit=forbidden,_prelaunchToInterplanetary=forbidden,_interplanetaryTargetSpec=forbidden)
        entry.call(prelaunch,'phasePrelaunch',env)
        assert events==['LAUNCH']
    survey=profile('kerbin_orbital_surveyor')
    assert survey['SCANSAT_DECOUPLER_TAG']=='' and survey['SCANSAT_AUTO_DEORBIT']==survey['SCANSAT_DISPOSE_CARRIER']==0
    assert survey['SCANSAT_POWER_LOW']<survey['SCANSAT_POWER_RESUME'] and survey['SCANSAT_REQUIRED_TYPES']
    land=profile('kerbin_lander')
    assert land['TARGET_LOCK']==land['LANDING_AUTO_TARGET']==land['LANDING_FLEXIBLE_SITE']==0
    assert land['ENTRY_POWERED_LANDING']==land['SCIENCE_ENTRY_CHUTES']==land['LANDING_TARGET_REVIEW_REQUIRED']==1
    assert land['ENTRY_LANDING_REQUIRE_POWER']==0 and land['ENTRY_LANDING_RESERVE_DV']==50
    assert land['ATMO_DEORBIT_PE']==52000 and land['ATMO_DEORBIT_PE_TOLERANCE']==1000
    assert land['SEQUENCE'][-5:]==['LANDING_REVIEW','ATMO_DEORBIT','SCIENCE_ENTRY','SURFACE_SCIENCE','DONE']
    radio=(ROOT/'lib/landing_radio.ks').read_text()
    env=dict(land,SHIP=NS(BODY=NS(NAME='Kerbin')),LANDING_RELAY_BODIES=Items(),LANDING_DIRECT_KERBIN_BODIES=Items(['Mun','Minmus']))
    assert entry.call(radio,'landingRequireKerbin',env)==0
    assert profile('duna_lander')['LANDING_REQUIRE_KERBIN']==1
    print('PASS: both local profiles launch directly to100km polar, skip transfers/capture, bind their own mapping/review bands; mapper hardware stays attached and Kerbin keeps52km entry without a fictitious center-of-Kerbin radio gate')


def check_chutes_with_optional_power():
    for fault in ('ok','no-thrust','no-chutes','fuel','nan-thrust','nan-fuel','invalid-policy'):
        env,ship,_,_=entry.fixture();kerbin(ship);env.update(profile('kerbin_lander'))
        ship.AVAILABLETHRUST=3 # TWR0.306: cannot support a powered touchdown.
        env['STAGE'].DELTAV.VACUUM=100
        if fault=='no-thrust':ship.AVAILABLETHRUST=0
        if fault=='no-chutes':ship.PARTS=[]
        if fault=='fuel':env['STAGE'].DELTAV.VACUUM=89
        if fault=='nan-thrust':ship.AVAILABLETHRUST=float('nan')
        if fault=='nan-fuel':env['STAGE'].DELTAV.VACUUM=float('nan')
        if fault=='invalid-policy':env['ENTRY_LANDING_REQUIRE_POWER']=2
        ready=env['entryLandingPreflight'](40)
        assert ready['OK']==(fault=='ok'),(fault,ready)
        if fault=='ok':
            assert ready['TWR']<1 and ready['REASON']=='chutes-with-optional-power'
            ctx=env['entryLandingCreate']();ship.ALTITUDE=ship.BOUNDS.BOTTOMALTRADAR=100
            assert not env['entryLandingTick'](ctx) and not ctx['ACTIVE'] and ctx['COMMAND']==0
            env['ENTRY_LANDING_REQUIRE_POWER']=1
            assert not env['entryLandingPreflight'](40)['OK']
    print('PASS: chute-led Kerbin descent permits sub-unity TWR but still pays deorbit+50m/s, requires current thrust/chutes/finite readings; the terminal controller issues no lift command without authority and required-powered mode still refuses the same craft')


def check_site_selection_and_atmo_admission():
    env,ship,state,events,overrides,_=review.fixture(True);kerbin(ship)
    cfg=profile('kerbin_lander');env.update(cfg);state.update(mission_id='kerbin_lander')
    ship.AVAILABLETHRUST=3;env['STAGE'].DELTAV.VACUUM=100
    env['opts']=native(dict(lat=0,lng=0)) # Explicit zero is valid; untouched defaults are not selection.
    entry.call(review.COMMAND,'_cmdLandsite',env)
    assert state['phase']=='ATMO_DEORBIT' and overrides['TARGET_LOCK']==1
    assert overrides['TARGET_LAT']==overrides['TARGET_LNG']==0 and not env['HASNODE'] and not events
    env,ship,state,events,nodes,world=atmo.fixture();kerbin(ship);env.update(cfg)
    env.update(TARGET_LAT=12,TARGET_LNG=45,TARGET_LOCK=1);state.update(mission_id='kerbin_lander')
    ship.AVAILABLETHRUST=3;env['STAGE'].DELTAV.VACUUM=100
    ctx=atmo.context(env,5025);node=nodes[0];node.NORMAL=3;ctx['EXPECTED'][1]=3
    node.ORBIT.PERIAPSIS=52000
    result=env['_atmoRead'](ctx)
    assert env['_atmoAccepted'](result,12,45,node)
    for pe in (5000,50000,54000,70000):
        result['PE']=pe
        assert not env['_atmoAccepted'](result,12,45,node),pe
    result['PE']=52000;world['light']=False
    assert not env['_atmoAccepted'](result,12,45,node) and 'burn' not in events
    print('PASS: explicit Kerbin coordinates save into the existing review/deorbit path; native-footprint admission accepts the configured52km Pe with optional power but rejects inherited Duna depth, corridor drift, no light and every unvalidated burn')


if __name__=='__main__':
    check_profiles_and_local_launch()
    check_chutes_with_optional_power()
    check_site_selection_and_atmo_admission()
