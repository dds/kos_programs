"""Real assist phase/continuation source with synthetic native patches, not KSP physics."""
from types import SimpleNamespace as NS
from copy import copy
import check_gravity_assist as g
from check_espoir_fleet import profile,Map,Items,native,literal
from check_surface_return import read_settings
from check_codebase import ROOT,dependency_tables,closure,function_body
from check_minmus_kolniya import execute
from arrival_fixture import EventEta


class Reboot(Exception):pass


def fixture(name='duna_orbital_surveyor',kac=True,time_scale=1,repeated=False):
    env,_,bodies,patches,nodes,events=g.fixture()
    cfg=profile(name)
    env.update(cfg)
    env.setdefault('MISSION_ASSIST_SCIENCE',0)
    # Native lexicons compare string keys without case. Match body spelling
    # in this small fixture map, which otherwise uses Python dict semantics.
    bands=cfg.get('SCIENCE_ENTRY_BANDS',Map())
    science_bands=Map({body.NAME:bands[body.NAME.upper()] for body in bodies if bands.HASKEY(body.NAME.upper())})
    saved=dict(mission_id=cfg['MISSION_ID'],vehicle='Espoir',launch_time=1000,phase='ASSIST')
    alarms={};overrides=[]
    env.update(xferSeq=cfg['SEQUENCE'],phaseShouldYield=False,
        getTarget=lambda:cfg['TARGET_'],
        KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),ADDONS=NS(KAC=NS(AVAILABLE=kac)),
        stateGet=saved.get,stateGetNum=saved.get,
        stateSet=lambda key,value:saved.__setitem__(key,value),stateRemove=lambda key:saved.pop(key,None),
        yieldToPrompt=lambda:env.__setitem__('phaseShouldYield',True),
        mLogSummary=lambda row:events.append(('log',row)),mLogError=lambda row:events.append(('error',row)),
        missionOverrideUpdate=lambda values:overrides.append(values),
        MISSION_ASSIST_SETTINGS=cfg['MISSION_ASSIST_SETTINGS'],
        scienceEntryContext=lambda:'context',shipPowerFraction=lambda:1,
        scienceFlightPulse=lambda *args:events.append(('science',args)),
        SCIENCE_ENTRY_BANDS=science_bands,SCIENCE_ENTRY_MIN_EC=.05)
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    env['bootLibBandForPhase']=lambda phase,fallback='':next((key for key,ps in bands.items() if phase.lower() in ps),phase if phase.lower() in phases else fallback)
    def advance(seq):
        i=seq.index(saved['phase']);nxt=seq[i+1] if i+1<len(seq) else 'DONE'
        saved['phase']=nxt;events.append(('phase',nxt));return nxt
    env['nextPhase']=advance
    def reload(reason,phase,band):saved.update(phase=phase,reload_reason=reason,lib_band=band)
    env['stateSaveReloadState']=reload
    def reboot():events.append(('reboot',saved['phase']));raise Reboot()
    env['fixture_reboot']=reboot
    def alarm(label,ut,*_):
        events.append(('alarm',label,ut))
        if not kac:return ''
        alarms[label]=ut;return label
    env['kacEnsureAlarm']=alarm
    env['DELETEALARM']=lambda key:alarms.pop(key,None)
    def soi(body,ut,*_):
        old=saved.get('soi_alarm_id','')
        if old:alarms.pop(old,None)
        aid=alarm('SOI '+body.NAME,ut)
        saved.update(soi_alarm_id=aid,soi_alarm_target=body.NAME,soi_alarm_ut=ut)
        return aid
    env['ensureSoiAlarm']=soi
    # The numerical crossing itself is separately tested against an
    # independent conic integral in check_arrival_policy.
    env['arrivalPatchRadiusUt']=lambda patch,alt,start:env['TIME'].SECONDS+patch.ETA.PERIAPSIS-100
    if name.startswith('ike_'):
        patches[1].ETA=EventEta(env['TIME'],11000)
        patches[2].PERIAPSIS=cfg['IKE_MISSION_SETTINGS']['CAPTURE_PE']
        if name=='ike_orbital_surveyor':patches[2].INCLINATION=90
    elif name=='duna_orbital_surveyor':
        patches[3].PERIAPSIS=300000;patches[3].INCLINATION=90
    else:patches[3].PERIAPSIS=5000
    if repeated:
        final=patches[3];final.ETA=EventEta(env['TIME'],20000)
        moon=copy(patches[2]);moon.ETA=EventEta(env['TIME'],17000);moon.NEXTPATCHETA=17000;moon.NEXTPATCH=final
        parent=copy(patches[1]);parent.ETA=EventEta(env['TIME'],15500);parent.NEXTPATCHETA=15000;parent.NEXTPATCH=moon
        patches[2].NEXTPATCH=parent
        patches[3:3]=[parent,moon]
        env['MISSION_ASSIST_ROUTE'].insert(1,Map(BODY='Ike',MIN_PE=25000))
    if time_scale!=1:
        for patch in patches:
            patch.ETA=EventEta(env['TIME'],(env['TIME'].SECONDS+patch.ETA.PERIAPSIS)*time_scale)
            if patch.HASNEXTPATCH:patch.NEXTPATCHETA=(env['TIME'].SECONDS+patch.NEXTPATCHETA)*time_scale-env['TIME'].SECONDS
    goal_index=2 if name.startswith('ike_') else len(patches)-1
    base_node=env['NODE']
    class Node(base_node):
        @property
        def ORBIT(self):
            # Separate hypothetical node propagation from the raw unburned
            # patch chain. The eccentricity response is synthetic physics.
            trial=[copy(patch) for patch in patches]
            for i in range(len(trial)-1):trial[i].NEXTPATCH=trial[i+1]
            trial[goal_index].ECCENTRICITY=max(.1,patches[goal_index].ECCENTRICITY-.04*self.PROGRADE)
            return trial[0]
    env['NODE']=Node
    ends={id(patch):env['TIME'].SECONDS+patch.NEXTPATCHETA for patch in patches if patch.HASNEXTPATCH}
    def move(now):
        env['TIME'].SECONDS=now
        for patch in patches:
            if patch.HASNEXTPATCH:patch.NEXTPATCHETA=ends[id(patch)]-now
        current=patches[0]
        while current.HASNEXTPATCH and now>=ends[id(current)]:current=current.NEXTPATCH
        env['SHIP'].ORBIT=current;env['SHIP'].BODY=current.BODY
    def wait(dt):move(env['TIME'].SECONDS+dt)
    env['fixture_wait']=wait
    env['enterSolarCoast']=lambda *args:events.append(('solar',args[-1])) or 1
    env['solarCoastCanWarp']=lambda *_:True
    env['coastAutoWarp']=lambda ut,*_:move(ut)
    env['trySolarHoldTick']=lambda ref,*_:ref
    def burn():
        events.append(('burn',nodes[0].DELTAV.MAG))
        patches[goal_index].ECCENTRICITY=max(.1,patches[goal_index].ECCENTRICITY-.04*nodes[0].PROGRADE)
        env['fixture_remove'](nodes[0]);return True
    env['executeManeuver']=burn
    return env,saved,events,alarms,overrides,patches,move


def coast(env):
    try:env['phaseAssistCoast']()
    except Reboot:return
    assert env['phaseShouldYield'],'coast neither handed off nor held'


def check_profiles_and_native_continuations():
    for name in ('duna_orbital_surveyor','ike_orbital_surveyor','ike_lander','duna_impactor','duna_science_impact'):
        env,saved,events,alarms,overrides,patches,_=fixture(name)
        # No profitable new correction: the existing safe native itinerary
        # can still replace Duna parking or preserve a free Ike science pass.
        env['planAssistRefinement']=lambda route:Map(OK=False,REASON='no-useful-affordable-improvement')
        env['phaseAssist']()
        assert saved['phase']=='ASSIST_COAST' and not env['phaseShouldYield'],(name,events)
        flight=saved['assist_flight']
        assert flight['index']==0 and flight['status']=='coast' and not any(e[0]=='burn' for e in events)
        coast(env)
        assert not env['phaseShouldYield'] and overrides and not alarms,(name,saved,events[-10:])
        values=overrides[-1];terminal='Ike' if name.startswith('ike_') else 'Duna'
        first='SCIENCE_ENTRY' if 'impactor'==name.split('_',1)[-1] and name.startswith('duna_') or name=='duna_science_impact' else 'CAPTURE'
        assert saved['target']==terminal and saved['phase']==first and saved['mission_id']==name
        assert 'MISSION_ID' not in values and not values['MISSION_ASSIST_ROUTE']
        # Apply the real recursive serializer to a fresh launch profile:
        # terminal settings must win without changing the profile identity.
        emitted='\n'.join('SET '+key+' TO '+str(literal(value))+'.' for key,value in values.items())
        fresh=read_settings(emitted,dict(profile(name)))
        assert fresh['MISSION_ID']==name and fresh['TARGET_']==terminal and fresh['SEQUENCE'][0]==first
        assert fresh['COAST_AUTO_WARP']==0
        assert 'ASSIST' not in fresh['SEQUENCE'] and 'XING' not in fresh['SEQUENCE']
        if name.startswith('ike_'):
            wanted=profile(name)['IKE_MISSION_SETTINGS']
            assert fresh['TARGET_AP']==wanted['TARGET_AP'] and fresh['CAPTURE_RESERVE_DV']==wanted['CAPTURE_RESERVE_DV']
            if name=='ike_lander':assert fresh['LANDING_REQUIRE_KERBIN']==1 and fresh['SCIENCE_SURFACE_DWELL']==600
        if name=='duna_science_impact':assert any(e[0]=='science' for e in events)
    print('PASS: all five Espoir profiles follow validated natural assists through actual ordered SOIs/Pe to correct capture or science entry; fresh-boot overrides preserve identity, mapping/landing/science settings and reserves')


def check_fallback_and_admission():
    for fault in ('no-seed','disabled','node','pilot','abort','fuel','config','reserve','runtime-plane','runtime-reserve','runtime-floor'):
        env,saved,events,_,overrides,patches,_=fixture()
        if fault=='no-seed':patches[2].HASNEXTPATCH=False
        if fault=='disabled':env['MISSION_ASSIST_ROUTE']=Items()
        if fault=='node':env['fixture_add'](env['NODE'](1600,0,0,0))
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.2
        if fault=='abort':env['ABORT']=True
        if fault=='fuel':env['SHIP'].DELTAV.VACUUM=50
        if fault=='config':env['MISSION_ASSIST_SETTINGS']['TARGET_AP']=500000
        if fault=='reserve':env['ASSIST_RESERVE_DV']=0
        if fault=='runtime-plane':env['CAPTURE_LAN']=1
        if fault=='runtime-reserve':env['CAPTURE_RESERVE_DV']=500
        if fault=='runtime-floor':env['CAPTURE_MIN_PE']=300000
        env['phaseAssist']()
        fallback=fault in ('no-seed','disabled','fuel')
        assert saved['phase']==('BPLANE' if fallback else 'ASSIST'),fault
        assert env['phaseShouldYield']!=fallback and not overrides and 'assist_flight' not in saved,fault
        assert not any(e[0]=='burn' for e in events)
        if fault=='node':assert env['HASNODE']
    print('PASS: absent opportunities/disabled/insufficient fuel continue original powered B-plane sequence; malformed goals, weaker reserves, foreign nodes, Abort and pilot control hold without burning or overwriting mission')


def check_owned_correction_and_reboot():
    for fault in ('','planned-reboot','burn-failure','cleaned-reboot','foreign','mismatch'):
        env,saved,events,_,_,_,_=fixture()
        burns=[]
        def planner(route):
            nd=env['NODE'](1600,0,0,4);env['fixture_add'](nd)
            return Map(OK=True,NODE=nd)
        env['planAssistRefinement']=planner
        original=env['stateSet']
        interrupted=[False]
        def save(key,value):
            original(key,value)
            if fault=='planned-reboot' and key=='assist_flight' and value['status']=='planned' and not interrupted[0]:
                interrupted[0]=True;raise Reboot()
        env['stateSet']=save
        def burn():
            burns.append(1)
            if fault=='burn-failure':return False
            env['fixture_remove'](env['NEXTNODE'])
            if fault=='cleaned-reboot' and not interrupted[0]:interrupted[0]=True;raise Reboot()
            return True
        env['executeManeuver']=burn
        try:env['phaseAssist']()
        except Reboot:pass
        if fault in ('planned-reboot','cleaned-reboot'):
            env['planAssistRefinement']=lambda _:(_ for _ in ()).throw(AssertionError('replanned committed assist'))
            env['phaseAssist']()
        if fault in ('foreign','mismatch'):
            # Reload an owned unflown node, then modify the same epoch/vector.
            saved['phase']='ASSIST';flight=saved['assist_flight'].COPY
            flight['status']='planned';saved['assist_flight']=flight
            nd=env['NODE'](1600,0,0,3);env['fixture_add'](nd)
            if fault=='foreign':nd.TIME+=1
            env['phaseAssist']()
            assert env['HASNODE'] and env['phaseShouldYield']
        elif fault=='burn-failure':assert env['phaseShouldYield'] and env['HASNODE'] and saved['phase']=='ASSIST'
        else:assert saved['phase']=='ASSIST_COAST' and not env['phaseShouldYield']
        assert len(burns)==1,fault
    print('PASS: committed corrections execute once, resume owned unflown nodes across reboot and reconcile cleaned burns from the raw trajectory; failed/interrupted/edited nodes stay held without replanning')


def check_live_wait_and_route_failures():
    for fault in ('no-kac','abort','new-node','pilot','lost-chain','late','resume'):
        env,saved,events,alarms,overrides,patches,move=fixture(kac=fault!='no-kac')
        env['planAssistRefinement']=lambda _:Map(OK=False)
        env['phaseAssist']()
        if fault=='late':move(15900)
        if fault=='resume':
            move(13001);saved['assist_flight']['index']=1;saved['assist_flight']['lastBody']='Ike'
        if fault in ('abort','new-node','pilot','lost-chain'):
            original=env['enterSolarCoast']
            def solar(*args):
                original(*args)
                if fault=='abort':env['ABORT']=True
                if fault=='new-node':env['fixture_add'](env['NODE'](5000,0,0,1))
                if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.2
                if fault=='lost-chain':patches[2].HASNEXTPATCH=False
                return 1
            env['enterSolarCoast']=solar
        coast(env)
        if fault in ('no-kac','resume'):
            assert overrides and saved['phase']=='CAPTURE' and not env['phaseShouldYield']
        else:assert env['phaseShouldYield'] and not overrides and saved['phase']=='ASSIST_COAST',fault
        assert not any(label.startswith('Assist') for label in alarms),fault
        assert not any(e[0]=='burn' for e in events)
        for i,event in enumerate(events):
            if event[0]=='solar':assert any(e[0]=='alarm' for e in events[:i])
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'gravity_assist' not in closure(phases['assist_coast'],deps)
    assert 'gravity_assist' in closure(phases['assist'],deps)
    print('PASS: resident coast alarms precede solar work, no-KAC clock and consumed-leg reboot resume; Abort/controls/new nodes/lost route/late capture hold, owned alarms clean up and the coast band excludes the optimizer')


def check_current_correction_admission():
    # Run the real bounded optimizer and mission executor path together.
    env,saved,events,_,_,_,_=fixture()
    env['phaseAssist']()
    assert saved['phase']=='ASSIST_COAST' and any(e[0]=='burn' for e in events) and not env['HASNODE']
    for fault in ('no-gain','expired','late-soi','low-thrust','pilot','interrupted','identity','status'):
        env,saved,events,_,_,patches,move=fixture()
        def planner(_):
            nd=env['NODE'](1600,0,0,4);env['fixture_add'](nd);return Map(OK=True,NODE=nd)
        env['planAssistRefinement']=planner
        save=env['stateSet']
        def stop(key,value):
            save(key,value)
            if key=='assist_flight' and value['status']=='planned':raise Reboot()
        env['stateSet']=stop
        try:env['phaseAssist']()
        except Reboot:pass
        env['stateSet']=save
        if fault=='no-gain':
            evaluate=env['assistEvaluate']
            def current(nd,*args):
                result=evaluate(nd,*args)
                if nd!=0 and result['OK']:result['COST']=evaluate(0,*args)['COST']+4
                return result
            env['assistEvaluate']=current
        if fault=='expired':move(1590)
        if fault=='late-soi':patches[0].NEXTPATCHETA=500
        if fault=='low-thrust':env['arrivalBurnSeconds']=lambda _:5000
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='interrupted':env['maneuverBurnInterrupted']=lambda:True
        if fault=='identity':saved['assist_flight']['mission']='other'
        if fault=='status':saved['assist_flight']['status']='broken'
        env['phaseAssist']()
        assert not any(e[0]=='burn' for e in events),fault
        if fault=='no-gain':assert saved['phase']=='ASSIST_COAST' and not env['HASNODE'] and not env['phaseShouldYield']
        else:assert saved['phase']=='ASSIST' and env['HASNODE'] and env['phaseShouldYield'],fault
    print('PASS: real optimizer reaches the owned execution path; preburn native gain, complete pre-SOI interval, live capture time/fuel, saved identity/status and pilot/interrupted guards prevent stale or unsafe burns')


def check_interrupted_terminal_write_and_cache():
    env,saved,events,alarms,overrides,_,_=fixture('ike_lander')
    env['planAssistRefinement']=lambda _:Map(OK=False)
    env['phaseAssist']()
    write=env['missionOverrideUpdate']
    def stopped(values):write(values);raise Reboot()
    env['missionOverrideUpdate']=stopped
    coast(env)
    assert saved['phase']=='ASSIST_COAST' and saved['assist_flight']['status']=='handoff'
    # A boot after the override copy but before the phase checkpoint has the
    # new continuation sequence and cleared optional config, yet the durable
    # flight record still supplies its route/settings to finish the handoff.
    env.update(overrides[-1]);env['xferSeq']=overrides[-1]['SEQUENCE']
    env['missionOverrideUpdate']=write
    coast(env)
    assert saved['phase']=='CAPTURE' and 'assist_flight' not in saved and saved['mission_id']=='ike_lander'
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    src=(ROOT/'lib/mission_type.ks').read_text()
    cfg=profile('duna_science_impact')
    roots=execute(function_body(src,'missionTypeConditionalRoots'),dict(cfg,bandKey='ASSIST_COAST',LIST=lambda:Items()))
    assert 'science_entry' in closure(roots,deps)
    print('PASS: reboot across terminal override writing completes the original identity/operations handoff and releases consumed state; optional flyby science has an explicit conditional coast provider')


def check_long_coast_checkpoint_cadence():
    env,saved,events,alarms,overrides,patches,move=fixture(time_scale=100)
    env['planAssistRefinement']=lambda _:Map(OK=False)
    env['phaseAssist']()
    first_midpoint=(env['TIME'].SECONDS+1000000)/2
    def warp(ut,*_):move(ut);raise Reboot()
    env['coastAutoWarp']=warp
    coast(env)
    assert env['TIME'].SECONDS==first_midpoint
    assert saved['assist_flight']['reviewUt']==first_midpoint
    env['coastAutoWarp']=lambda ut,*_:move(ut)
    coast(env)
    wakes=[e[2] for e in events if e[0]=='alarm' and e[1]=='Assist encounter wake']
    assert wakes.count(first_midpoint)==1 and len(wakes)<=8,wakes
    assert overrides and saved['phase']=='CAPTURE' and 'assist_flight' not in saved and not alarms
    print('PASS: multi-day transfer uses one anchored review per long body passage plus native events, survives midpoint reboot and avoids 15-minute/near-Pe alarm and solar churn')


def check_repeated_flyby_progress():
    env,saved,events,alarms,overrides,_,_=fixture(repeated=True)
    env['planAssistRefinement']=lambda _:Map(OK=False)
    env['phaseAssist']()
    indices=[];save=env['stateSet']
    def track(key,value):
        if key=='assist_flight' and value['index']>0 and value['index'] not in indices:indices.append(value['index'])
        save(key,value)
    env['stateSet']=track
    coast(env)
    assert indices==[1,2] and saved['phase']=='CAPTURE' and overrides and not alarms
    assert 'assist_flight' not in saved and not any(e[0]=='burn' for e in events)
    print('PASS: repeated encounters with the same moon consume distinct physically observed periapses and finish at the terminal planet without duplicate phase names or double-counting the outgoing patch')


if __name__=='__main__':
    check_profiles_and_native_continuations()
    check_fallback_and_admission()
    check_owned_correction_and_reboot()
    check_live_wait_and_route_failures()
    check_current_correction_admission()
    check_interrupted_terminal_write_and_cache()
    check_long_coast_checkpoint_cadence()
    check_repeated_flyby_progress()
