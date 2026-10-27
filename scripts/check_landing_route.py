"""Landing-route reference costs and geometry; no native descent guarantee."""
import copy
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask, command_entrypoint_errors, dependency_tables, closure
from check_landing_orbit import fixture, Lex, Seq, ROUTE


def momentum_speed(mu,first_radius,second_radius,at_radius):
    # Independent orbital invariants: energy=-mu/(r1+r2), h^2=2mu*r1*r2/(r1+r2).
    energy=-mu/(first_radius+second_radius)
    momentum=math.sqrt(mu*(-2*energy/mu)*first_radius*second_radius)
    return momentum/at_radius


def check_kolniya_reference():
    env,saved,events,nodes,_=fixture()
    original=copy.deepcopy(saved)
    targets=env['landingPrepTargets']()
    result=env['landingRouteEstimate'](targets,0,0,2.45)
    assert result['VALID'] and not nodes and saved==original and not events
    assert abs(result['PREP_MIN']-45.457227)<1e-5
    assert result['PREP_MIN']==result['PREP_MAX']
    assert 226<result['DIRECT_TOTAL']<227 and 230<result['PARK_TOTAL_MIN']<231
    assert 4<result['PARK_TOTAL_MIN']-result['DIRECT_TOTAL']<4.2
    assert 20199<result['PERIOD_BEFORE']<20201 and 3028<result['PERIOD_AFTER']<3029
    assert 60359<result['CROSSING_BEFORE'][0]<60360
    assert 13963<result['CROSSING_AFTER'][0]<13964
    assert 56<result['DIRECT_ALLOWANCE']<57 and 44<result['PARK_ALLOWANCE']<45
    available=env['SHIP'].DELTAV.VACUUM
    assert result['PREP_RESERVE_MARGIN']==available-result['PREP_MAX']-900
    # The prep reserve is a post-preparation floor. Do not silently turn
    # it into a new post-landing reserve or a landing-burn fuel allowance.
    assert result['DIRECT_REMAIN']==available-result['DIRECT_TOTAL']
    assert result['PARK_REMAIN']==available-result['PARK_TOTAL_MAX']
    print('PASS: actual9.3x397.272km Kolniya reference trades45.46m/s preparation against41.35m/s descent savings, changes equatorial crossing60.36->13.96km/period20200->3028s, and reports reserve/remainder without changing mission state or nodes')


def check_general_reference_orders():
    for old_pe,old_ap,new_pe,new_ap in ((9300,19300,9300,19300),(200000,500000,11000,21000),
                                       (10000,10000,15000,90000),(30000,70000,50000,100000)):
        env,_,_,_,_=fixture(False)
        env['LAND_PREP_MIN_PE']=9000
        env['SHIP'].PERIAPSIS=old_pe;env['SHIP'].APOAPSIS=old_ap
        targets=Lex(PE=new_pe,AP=new_ap,INC=63.4,LAN=79.2)
        actual=env['landingRouteEstimate'](targets,0,0,3)
        assert actual['VALID']
        rr=60000;mu=1.7658e9
        pe0,ap0,pe1,ap1=(rr+alt for alt in (old_pe,old_ap,new_pe,new_ap))
        speed=lambda first,second,at:momentum_speed(mu,first,second,at)
        order_a=abs(speed(pe0,ap1,pe0)-speed(pe0,ap0,pe0))+abs(speed(pe1,ap1,ap1)-speed(pe0,ap1,ap1))
        order_b=abs(speed(pe1,ap0,ap0)-speed(pe0,ap0,ap0))+abs(speed(pe1,ap1,pe1)-speed(pe1,ap0,pe1))
        assert abs(actual['PREP_MIN']-min(order_a,order_b))<1e-9
        assert abs(actual['PREP_MAX']-max(order_a,order_b))<1e-9
        if (old_pe,old_ap)==(new_pe,new_ap):
            assert actual['PREP_MIN']==0 and actual['DIRECT_TOTAL']==actual['PARK_TOTAL_MAX']
    print('PASS: unchanged, lowered, raised and crossing apsis transfers match independent energy/angular-momentum references for both ordinary burn orders')


def check_geometry_and_limits():
    env,_,_,_,_=fixture()
    target=env['landingPrepTargets']()
    for fault in ('plane','latitude','atmo','patch','surface','nan-alt','invalid-target','unbound'):
        local=dict(env);local['SHIP']=copy.deepcopy(env['SHIP']);targets=Lex(target)
        latitude,elevation=0,0
        if fault=='plane':targets['INC']=90
        if fault=='latitude':latitude=80
        if fault=='atmo':local['SHIP'].BODY.ATM.EXISTS=True
        if fault=='patch':local['SHIP'].ORBIT.HASNEXTPATCH=True
        if fault=='surface':elevation=10000
        if fault=='nan-alt':local['SHIP'].APOAPSIS=math.nan
        if fault=='invalid-target':targets['AP']=1
        if fault=='unbound':local['SHIP'].ORBIT.ECCENTRICITY=1
        assert not ks.call('landingRouteEstimate',local,targets,latitude,elevation,3)['VALID'],fault
    for acceleration in (0,.4905,.4,math.nan,math.inf):
        report=env['landingRouteEstimate'](target,0,0,acceleration)
        assert report['VALID'] and not report['ALLOWANCE_VALID']
        assert report['DIRECT_ALLOWANCE']==report['PARK_ALLOWANCE']==-1
    stop=[]
    for inclination in (0,180):
        env['SHIP'].ORBIT.INCLINATION=inclination;target['INC']=inclination
        report=env['landingRouteEstimate'](target,0,0,3)
        stop.append(report['DIRECT_STOP'])
        assert report['CROSSING_BEFORE']==[9300,397272]
    assert abs(stop[1]-stop[0]-2*math.pi*60000/40400*2)<1e-9
    print('PASS: plane/latitude/atmosphere/patch/surface/nonfinite/unbound inputs cannot produce a valid comparison; low/invalid TWR has no invented gravity allowance; equatorial and retrograde rotation remain physical')


def check_snapshot_and_command():
    env,saved,events,nodes,_=fixture()
    env['landingResolveTarget']=lambda:Lex(FOUND=True,LAT=35,LNG=82)
    terrain=[]
    env['LATLNG']=lambda lat,lng:terrain.append((lat,lng)) or NS(TERRAINHEIGHT=1200)
    report=env['landingRouteSnapshot'](env['landingPrepTargets']())
    assert report['TARGET_KNOWN'] and report['LAT']==35 and report['ELEVATION']==1200
    assert report['DESCENT_ACC']==2.72 and terrain==[(35,82)] and not events and not nodes
    command=(ROOT/'cmd/landingroute.ks').read_text()
    assert not command_entrypoint_errors(command)
    assert 'diagnosticArchiveOpen("landingroute")' in command and 'diagnosticArchiveClose(' in command
    assert not re.search(r'(?<!:)\b(?:STAGE|LOCK|UNLOCK|ADD|REMOVE|REBOOT)\b|\b(?:stateSet|stateRemove|missionOverrideUpdate)\(',mask(command))
    assert not re.search(r'\b(?:stateSet|stateRemove|executeManeuver|NODE|STAGE|LOCK|UNLOCK)\b',mask(ROUTE))
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'landing_route' in closure(phases['land_prep'],deps)
    assert not {'maneuver','orbit_shape','landing_main','landing_prediction','deorbit_targeting'}&closure(['landing_route'],deps)
    print('PASS: read-only snapshot uses the resolved waypoint/terrain and weaker measured landing acceleration; standalone archive command creates no node or mission override, and the small shared module avoids all powered/planner controllers')


if __name__=='__main__':
    check_kolniya_reference()
    check_general_reference_orders()
    check_geometry_and_limits()
    check_snapshot_and_command()
