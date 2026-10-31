"""Molniya pair source/reboot guards plus independent impulses; not native KSP."""
import copy
import math
import re
from types import SimpleNamespace as NS

import check_relay_constellation as relay
import check_entry_landing as entry
import check_espoir_fleet as fleet
from check_codebase import ROOT, closure, dependency_tables, function_body
from check_surface_return import read_settings

SOURCE=(ROOT/'lib/molniya_pair.ks').read_text()
SHAPE=(ROOT/'lib/orbit_shape.ks').read_text()


def fixture():
    env,ship,saved,events,alarms,released,nodes=relay.fixture()
    cfg=fleet.profile('kerbin_molniya_pair');env.update(cfg)
    bdy=NS(NAME=fleet.Text('Kerbin'),MU=3.5316e12,RADIUS=600000,SOIRADIUS=84159286,
           ATM=NS(EXISTS=True,HEIGHT=70000))
    ship.BODY=bdy;ship.AVAILABLETHRUST=5
    def orbit(ap,pe,aop):
        sma=bdy.RADIUS+(ap+pe)/2;ecc=(ap-pe)/(2*sma)
        out=relay.Orbit(bdy,sma,ecc)
        out.INCLINATION=63.4;out.LAN=45;out.ARGUMENTOFPERIAPSIS=aop
        return out
    ship.ORBIT=orbit(cfg['MOLNIYA_PAIR_AP'],cfg['MOLNIYA_PAIR_PE'],270)
    keep=[env['CORE'].PART,ship.PARTSTAGGED('relay_1')[0],*ship.PARTSTAGGED('relay_1')[0].CHILDREN]
    ship.PARTS[:]=keep
    core=env['CORE'].PART
    core.modules['ModuleCommand']=relay.Module()
    core.RESOURCES=[NS(NAME='ElectricCharge',AMOUNT=300,CAPACITY=300)]
    ant=relay.Part('carrier-relay',name='restock-relay-radial-2_v2',modules={
        'ModuleDataTransmitter':relay.Module(),'ModuleDeployableAntenna':relay.Module(['Extend Antenna'])})
    ship.PARTS.append(ant)
    for idx in range(6):ship.PARTS.append(relay.Part('carrier-solar'+str(idx),modules={'ModuleDeployableSolarPanel':relay.Module()}))
    for part in ship.PARTS:part.SHIP=ship
    dc=ship.PARTSTAGGED('relay_1')[0]
    def release(event):
        assert event=='Decouple' and not dc.ISDECOUPLED
        dc.ISDECOUPLED=True
        child=NS(BODY=bdy,ORBIT=copy.copy(ship.ORBIT),NAME=fleet.Text('North'))
        for part in dc.CHILDREN:ship.PARTS.remove(part);part.SHIP=child
        released.append(child);events.append('release')
    dc.modules['ModuleAnchoredDecoupler'].DOEVENT=release
    env.update(MOD=lambda x,y:x%y,getTarget=lambda:fleet.Text('Kerbin'),fixture_reboot=lambda:events.append('reboot'),
        SHAPE_TOTAL_DV_CAP=2500,phaseShouldYield=False,fixture_orbit=orbit,carrier_antenna=ant,STAGE=NS(DELTAV=NS(VACUUM=1500)))
    saved.update(mission_id=fleet.Text('kerbin_molniya_pair'),phase=fleet.Text('MOLNIYA_PAIR'),
        shape_budget_id='Kerbin:100',shape_budget_spent=700)
    updates={}
    env['missionOverrideUpdate']=lambda values:updates.update(values)
    env['stateSaveReloadState']=lambda reason,phase,band:saved.update(phase=phase,reload_reason=reason,reload_next_band=band)
    for name in re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:relay.invoke(SOURCE,name,env,*args)
    return env,ship,saved,events,released,updates


def run(env):return env['phaseMolniyaPair']()


def check_profiles_and_geometry():
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for name,aop in [('kerbin_molniya_north',270),('kerbin_molniya_south',90),('kerbin_molniya_pair',270)]:
        cfg=fleet.profile(name);mu=3.5316e12;br=600000
        ap,pe=cfg['SHAPE_AP'],cfg['SHAPE_PE'];sma=br+(ap+pe)/2
        ecc=(ap-pe)/(2*sma);period=2*math.pi*math.sqrt(sma**3/mu)
        assert 9697<period<11852 and abs(period-10774)<.01 and ecc>.6
        assert 63<cfg['SHAPE_INC']<64 and cfg['SHAPE_AOP']==aop
        assert pe>80000 and cfg['SHAPE_MIN_PE']==80000
        assert cfg['LAUNCH_INCLINATION']==63.4 and cfg['LAUNCH_PLANE_MODE']=='' and cfg['SHAPE_LAN']==-1
        assert cfg['COAST_AUTO_WARP']==0 and not {'XING','CAPTURE','MOLNIYA_INSERT'} & set(cfg['SEQUENCE'])
        # Independent apocentre latitude establishes the requested hemisphere.
        dwell=math.degrees(math.asin(math.sin(math.radians(63.4))*math.sin(math.radians(aop+180))))
        assert abs(dwell-(63.4 if aop==270 else -63.4))<1e-10
        for phase in cfg['SEQUENCE']:assert phase.lower() in phases
    assert bands['molniya_pair']==['molniya_pair']
    assert not {'maneuver','orbit_shape','launch','landing_main'} & closure(phases['molniya_pair'],deps)
    assert {'relay_hardware','relay_release','thrust_cutoff'}<=closure(phases['molniya_pair'],deps)
    assert 'relay_release' in closure(['relay_constellation'],deps)
    print('PASS: three profiles use native SHAPE, 10774s/e0.65/63.4deg and north270/south90 apocentres; safe163.584km Pe, lean pair band and unchanged KAC/executor ownership')


def check_two_orbits_with_real_planner():
    env,ship,saved,events,released,updates=fixture()
    run(env)
    assert len(released)==1 and saved['relay_1_record']['VALID']
    assert updates['SHAPE_AP']==updates['SHAPE_PE']==2999751 and updates['SHAPE_AOP']==-1
    assert updates['SHAPE_LAN']==45 and saved['shape_budget_spent']==700
    assert events[-1]=='reboot' and saved['phase']=='SHAPE' and saved['relay_pair_leg']=='circle'
    costs=[];placed=[]
    for leg in ('circle','south'):
        # Fresh profile/override serialization, as at a boot. No old derived
        # native node is persisted. Existing SHAPE spending is retained.
        cfg=read_settings('\n'.join('SET '+k+' TO '+str(fleet.literal(v))+'.' for k,v in updates.items()),dict(env))
        env.update(cfg)
        targets=fleet.Map(AP=cfg['SHAPE_AP'],PE=cfg['SHAPE_PE'],INC=63.4,LAN=45)
        if cfg['SHAPE_AOP']>=0:targets['AOP']=cfg['SHAPE_AOP']
        orb=ship.ORBIT
        # Actual planner decisions against a separate Kepler impulse adapter.
        se=dict(cfg,MIN_AOP_TARGET_ECC=.004,NEAR_CIRC_ECC=.01,SHAPE_AOP_TOL=.5,
            ETA=NS(PERIAPSIS=100,APOAPSIS=200),TIME=env['TIME'],SHIP=ship,
            _peFloor=lambda:80000,
            etaToTrueAnomaly=lambda _:orb.PERIOD/2,
            shapeErrors=lambda _:fleet.Map(AP=ship.APOAPSIS-targets['AP'],PE=ship.PERIAPSIS-targets['PE'],PLANE=0),
            _targetEcc=lambda _: (targets['AP']-targets['PE'])/(2*ship.BODY.RADIUS+targets['AP']+targets['PE']))
        def placed_ta(aop):placed.append(aop);return (aop-orb.ARGUMENTOFPERIAPSIS)%360
        se['_placedApsisTa']=placed_ta
        def impulse(eta,ta,opposite,label,*_):
            br=ship.BODY.RADIUS;mu=ship.BODY.MU
            rmag=orb.a*(1-orb.e**2)/(1+orb.e*math.cos(math.radians(ta)))
            speed0=math.sqrt(mu*(2/rmag-1/orb.a));sma=(rmag+br+opposite)/2
            speed1=math.sqrt(mu*(2/rmag-1/sma));cost=abs(speed1-speed0)
            arglat=(ta+orb.ARGUMENTOFPERIAPSIS)%360
            new_aop=(arglat if speed1>math.sqrt(mu/rmag) else arglat-180)%360
            after=env['fixture_orbit'](max(rmag-br,opposite),min(rmag-br,opposite),new_aop)
            costs.append(cost);return fleet.Map(node=NS(ORBIT=after,DELTAV=NS(MAG=cost)),label=label)
        se['_apsisBurn']=impulse
        ship.ALTITUDE=ship.APOAPSIS
        plan=entry.call(SHAPE,'shapeNextBurn',se,targets)
        assert plan['label']==('set-pe' if leg=='circle' else 'placed-ap'),plan
        ship.ORBIT=plan['node'].ORBIT
        env['STAGE'].DELTAV.VACUUM-=costs[-1];saved['shape_budget_spent']+=costs[-1]
        saved['phase']='MOLNIYA_PAIR';run(env)
    assert costs and abs(sum(costs)-809.015)<.01 and len(released)==1
    assert placed==[270] # South apocentre, thus north-facing periapsis (AoP90).
    assert env['_pairOrbit'](ship,90) and env['_pairOrbit'](released[0],270)
    assert 'next' in events and env['STAGE'].DELTAV.VACUUM>600
    assert saved['shape_budget_spent']>1509 and saved['mission_id']=='kerbin_molniya_pair'
    assert updates['SEQUENCE']==['SHAPE','MOLNIYA_PAIR','DONE']
    print('PASS: actual SHAPE planner selects one high-circle burn then opposite-side placed-ap burn; independent impulses cost809.015m/s and produce both valid orbits, one physical release, no plane change or ledger reset')


def check_release_and_context_guards():
    for fault in ('ok','abort','yield','warp','node','interrupted','deorbit','pilot','active','wrong-body','atmosphere',
                  'first-aop','first-ecc','first-inc','first-period','carrier-antenna','carrier-panels',
                  'carrier-command','carrier-battery','carrier-jam','payload-staged','payload-direct',
                  'fuel','nan-fuel','budget','foreign','ambiguous','unbound-record','incomplete-record','policy'):
        env,ship,saved,events,released,updates=fixture()
        if fault=='abort':env['ABORT']=True
        if fault=='yield':env['phaseShouldYield']=True
        if fault=='warp':env['WARP']=2
        if fault=='node':env['HASNODE']=True
        if fault=='interrupted':saved['burn_started']='true'
        if fault=='deorbit':saved['deorbit_burn_started']='true'
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='active':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='wrong-body':ship.BODY.NAME='Mun'
        if fault=='atmosphere':ship.ORBIT=env['fixture_orbit'](2999751,70000,270)
        if fault=='first-aop':ship.ORBIT.ARGUMENTOFPERIAPSIS=90
        if fault=='first-ecc':ship.ORBIT.e=.59
        if fault=='first-inc':ship.ORBIT.INCLINATION=62.9
        if fault=='first-period':ship.ORBIT.a*=1.5
        if fault=='carrier-antenna':env['carrier_antenna'].NAME=fleet.Text('restock-antenna-stack-2')
        if fault=='carrier-panels':ship.PARTS[-1].modules.clear()
        if fault=='carrier-command':env['CORE'].PART.modules.clear()
        if fault=='carrier-battery':env['CORE'].PART.RESOURCES[0].CAPACITY=100
        if fault=='carrier-jam':env['carrier_antenna'].GETMODULE('ModuleDeployableAntenna').DOEVENT=lambda _:None
        if fault=='payload-staged':ship.PARTSTAGGED('relay_1')[0].STAGED=True
        if fault=='payload-direct':ship.PARTSTAGGED('relay_1')[0].CHILDREN[1].NAME=fleet.Text('restock-antenna-stack-2')
        if fault=='fuel':env['STAGE'].DELTAV.VACUUM=900
        if fault=='nan-fuel':env['STAGE'].DELTAV.VACUUM=math.nan
        if fault=='budget':env['SHAPE_TOTAL_DV_CAP']=1400
        if fault=='foreign':saved['relay_pair_campaign']='another-mission'
        if fault=='ambiguous':saved['relay_1_intent']=fleet.Map(UIDS=['payload'])
        if fault=='unbound-record':saved['relay_1_record']=fleet.Map(VALID=True,UID='payload',PERIOD=10774)
        if fault=='incomplete-record':saved['relay_1_record']=fleet.Map(VALID=True)
        if fault=='policy':env['RELAY_VERIFY_HARDWARE']=0
        run(env)
        if fault=='ok':assert len(released)==1 and updates
        else:
            assert not released and not updates and 'hold' in events and 'next' not in events,(fault,events)
            if fault=='node':assert env['HASNODE']
    print('PASS: control/ownership/native bounds, independent retained hardware, passive staged-off branch, antenna readiness, active-stage fuel and cumulative budget prevent unsafe separation; evidence and foreign nodes retained')


def check_reboot_proof_and_native_bad_kick():
    class Reboot(Exception):pass
    for cut in ('record','status','overrides','phase','south-status','south-overrides','south-phase'):
        env,ship,saved,events,released,updates=fixture();put=env['stateSet'];rewrite=env['missionOverrideUpdate'];save=env['stateSaveReloadState'];hit=[False]
        southern=cut.startswith('south-')
        if southern:
            run(env);ship.ORBIT=env['fixture_orbit'](2999751,2999751,270)
            saved['phase']='MOLNIYA_PAIR';cut=cut[6:]
        def crash():
            if not hit[0]:hit[0]=True;raise Reboot()
        def write(key,value):
            put(key,value)
            if (cut=='record' and key=='relay_1_record') or (cut=='status' and key=='relay_pair_leg'):crash()
        def overrides(values):
            rewrite(values)
            if cut=='overrides':crash()
        def commit(*args):
            save(*args)
            if cut=='phase':crash()
        env.update(stateSet=write,missionOverrideUpdate=overrides,stateSaveReloadState=commit)
        try:run(env)
        except Reboot:pass
        run(env)
        assert len(released)==1 and saved['relay_pair_leg']==('south' if southern else 'circle') and saved['phase']=='SHAPE'
        assert updates['SHAPE_AP']==2999751 and updates['SHAPE_PE']==(163584 if southern else 2999751)
        assert saved['shape_budget_spent']==700
    for fault in ('ambiguous','bad-kick','final-aop','lost-carrier-relay'):
        env,ship,saved,events,released,updates=fixture()
        dc=ship.PARTSTAGGED('relay_1')[0];release=dc.GETMODULE('ModuleAnchoredDecoupler').DOEVENT
        def kick(event):
            release(event)
            if fault=='ambiguous':raise Reboot()
            released[0].ORBIT.ARGUMENTOFPERIAPSIS=90
        if fault in ('ambiguous','bad-kick'):dc.GETMODULE('ModuleAnchoredDecoupler').DOEVENT=kick
        try:run(env)
        except Reboot:pass
        if fault in ('final-aop','lost-carrier-relay'):
            saved['relay_pair_leg']='south';ship.ORBIT=env['fixture_orbit'](2999751,163584,270 if fault=='final-aop' else 90)
            if fault=='lost-carrier-relay':env['carrier_antenna'].NAME=fleet.Text('direct-only')
            events.clear();updates.clear()
        run(env)
        assert len(released)==1 and 'hold' in events and 'next' not in events
        if fault=='bad-kick':assert not saved['relay_1_record']['VALID']
    print('PASS: reboot at proof/status/override/phase writes never separates twice; ambiguous physical release, native orbit kick and invalid final carrier preserve evidence and hold instead of declaring a network')


if __name__=='__main__':
    check_profiles_and_geometry()
    check_two_orbits_with_real_planner()
    check_release_and_context_guards()
    check_reboot_proof_and_native_bad_kick()
