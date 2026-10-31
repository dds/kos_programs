"""Actual parking/site command and compatibility source; no native kOS VM."""
import re
from types import SimpleNamespace as NS
import check_entry_landing as entry
from check_codebase import ROOT,function_body,dependency_tables,closure
from check_espoir_fleet import native,Map,Items,profile

REVIEW=(ROOT/'lib/landing_review.ks').read_text()
COMMAND=(ROOT/'cmd/landsite.ks').read_text()
COMMAND=COMMAND.replace('LOCAL lat IS 999.','LOCAL lat IS fixtureScalar().').replace('LOCAL lng IS 999.','LOCAL lng IS fixtureScalar().')
BOOT=(ROOT/'lib/boot_lib.ks').read_text()


def fixture(air=True):
    env,ship,state,events=entry.fixture()
    ship.STATUS='ORBITING';ship.PERIAPSIS=ship.APOAPSIS=70000
    ship.ORBIT=NS(HASNEXTPATCH=False,ECCENTRICITY=0,INCLINATION=90)
    ship.BODY.ATM.EXISTS=air
    if not air:ship.BODY.NAME='Ike';state['mission_id']='ike_lander_ops'
    state.update(vehicle='Espoir',phase='LANDING_REVIEW')
    overrides={};world=dict(waypoint=0,loaded=True)
    env.update(opts=Map(),HASNODE=False,HOMECONNECTION=NS(ISCONNECTED=True),
        SEQUENCE=Items(['LANDING_REVIEW','ATMO_DEORBIT' if air else 'LAND_DEORBIT','SCIENCE_ENTRY','DONE']),
        CHAR=chr,fixtureScalar=lambda:native(999),orbitSummary=lambda:events.append('orbit'),
        orientForSolar=lambda *args:events.append('solar'),
        bootPreamble=lambda:None,RUNPATH=lambda *_:None,
        bootLibLoad=lambda *_:None,bootApplyMissionConfig=lambda *_:world['loaded'],
        getTarget=lambda:ship.BODY.NAME,
        selectedWaypoint=lambda:world['waypoint'],
        missionOverrideUpdate=lambda values:overrides.update(values),
        stateSet=lambda key,value:state.update({key:value}),
        yieldToPrompt=lambda:events.append('hold'),
        landingOrbitContext=lambda:ship.BODY.NAME+':'+state['mission_id']+':1000',
        fixture_settle=lambda:None)
    for name in ('landingReviewOrbitSafe','phaseLandingReview'):
        env[name]=lambda name=name:entry.call(REVIEW,name,env)
    return env,ship,state,events,overrides,world


def check_hold_and_site_command():
    for air in (False,True):
        for kind in ('coords','waypoint','missing','partial','nan','string','wrong-type','abort','node',
                     'thrust','pilot','warp','falling','body-switch','pe','ecc','patch','burn',
                     'wrong-phase','unreachable','no-fuel','bad-profile'):
            env,ship,state,events,overrides,world=fixture(air)
            env['opts']=native(dict(lat=12,lng=45))
            if kind=='waypoint':
                env['opts']=Map();world['waypoint']=NS(GEOPOSITION=NS(LAT=native(12),LNG=native(45)))
            if kind=='missing':env['opts']=Map()
            if kind=='partial':env['opts']=native(dict(lat=12))
            if kind=='nan':env['opts']=native(dict(lat=float('nan'),lng=45))
            if kind=='string':env['opts']=native(dict(lat='12',lng=45))
            if kind=='wrong-type':env['opts']=native('wrong')
            if kind=='abort':env['ABORT']=True
            if kind=='node':env['HASNODE']=True
            if kind=='thrust':ship.THRUST=1
            if kind=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
            if kind=='warp':env['WARP']=1
            if kind=='falling':ship.STATUS='SUB_ORBITAL'
            if kind=='body-switch':env['KUNIVERSE'].ACTIVEVESSEL=NS()
            if kind=='pe':ship.PERIAPSIS=-1
            if kind=='ecc':ship.ORBIT.ECCENTRICITY=float('nan')
            if kind=='patch':ship.ORBIT.HASNEXTPATCH=True
            if kind=='burn':state.update(burn_started='true',burn_pending='true')
            if kind=='wrong-phase':state['phase']='SCIENCE_ENTRY'
            if kind=='unreachable':ship.ORBIT.INCLINATION=0
            if kind=='no-fuel':env['STAGE'].DELTAV.VACUUM=0
            if kind=='bad-profile':world['loaded']=False
            before=state.copy()
            entry.call(COMMAND,'_cmdLandsite',env)
            accepted=kind in ('coords','waypoint') or (kind=='no-fuel' and not air)
            assert bool(overrides)==accepted,(air,kind,state,events)
            if accepted:
                assert overrides['TARGET_LAT']==12 and overrides['TARGET_LNG']==45
                assert overrides['TARGET_LOCK']==1 and overrides['LANDING_AUTO_TARGET']==0
                assert state['phase']==('ATMO_DEORBIT' if air else 'LAND_DEORBIT')
                assert state['mission_id']==before['mission_id'] and state['launch_time']==1000
                assert state['landing_site_context']==env['landingOrbitContext']()
                assert not env['HASNODE'] and not events
            else:assert state==before and not events
    env,ship,state,events,_,_=fixture()
    env['phaseLandingReview']()
    assert state['phase']=='LANDING_REVIEW' and events==['cutoff','orbit','solar','hold']
    print('PASS: parking review never advances or creates a node; explicit waypoint/numeric site preserves identity, and unsafe orbit/control/context/hardware/coordinates cannot write landing intent')


def check_legacy_ops_upgrade():
    for mid in ('ike_lander_ops','ike_orbital_surveyor_ops'):
        for status,begun in (('ORBITING',False),('ORBITING',True),('SUB_ORBITAL',False)):
            cfg=profile(mid.removesuffix('_ops'))['IKE_MISSION_SETTINGS']
            env=dict(cfg,cn='Espoir',mid=mid,SHIP=NS(STATUS=status),
                stateGet=lambda key,default='':('true' if begun else 'false'),
                LIST=lambda *xs:Items(xs))
            env.update(CAPTURE_INC=-1,CAPTURE_PE=150000,LANDING_AUTO_TARGET=1,
                       LANDING_TARGET_REVIEW_REQUIRED=0)
            # Observe global SETs just as profile boot does.
            from check_minmus_kolniya import execute
            execute(function_body(BOOT,'bootMissionProfileIntent'),env)
            if status=='ORBITING' and not begun:
                assert env['CAPTURE_INC']==90
                if mid=='ike_orbital_surveyor_ops':assert env['CAPTURE_PE']==env['SHAPE_PE']==70000
                else:
                    assert env['LANDING_TARGET_REVIEW_REQUIRED']==1 and env['LANDING_AUTO_TARGET']==0
                    assert env['SEQUENCE'].index('LANDING_REVIEW')<env['SEQUENCE'].index('LAND_DEORBIT')
            else:assert env['CAPTURE_INC']==-1 and env['LANDING_TARGET_REVIEW_REQUIRED']==0
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    ordinary=closure(phases['science_entry'],deps)
    assert 'entry_landing' not in ordinary and 'atmo_deorbit' not in ordinary
    assert {'landing_review','entry_landing_math'}<=closure(phases['landing_review'],deps)
    print('PASS: old generated Ike profiles upgrade only while uncommitted in orbit; suborbital/begun descent retains its recipe, and powered atmospheric control stays outside ordinary science entry')


def check_old_deorbit_routes_to_review():
    source=(ROOT/'lib/landing_deorbit.ks').read_text()
    for selected in (False,True):
        env,ship,state,events,_,_=fixture(False)
        state['phase']='LAND_DEORBIT'
        if selected:state['landing_site_context']=env['landingOrbitContext']()
        env.update(LANDING_TARGET_REVIEW_REQUIRED=1,HASNODE=True,
            landingApplyMissionConfig=lambda:None,
            vesselLandingPrepareRoles=lambda:events.append('roles') or False)
        entry.call(source,'phaseLandDeorbit',env)
        assert state['phase']==('LAND_DEORBIT' if selected else 'LANDING_REVIEW')
        assert events==(['roles','hold'] if selected else ['hold']) and env['HASNODE']
    print('PASS: an old unselected orbital LAND_DEORBIT checkpoint redirects before roles/search/node deletion; saved selected intent bypasses only the review gate and still meets ordinary safety guards')


if __name__=='__main__':
    check_hold_and_site_command()
    check_legacy_ops_upgrade()
    check_old_deorbit_routes_to_review()
