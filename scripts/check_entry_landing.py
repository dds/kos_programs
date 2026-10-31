"""Powered atmospheric terminal source, independent point-mass physics; not KSP."""
import math
import re
from functools import lru_cache
from types import SimpleNamespace as NS
import check_landing_guidance as ks
from check_codebase import ROOT,function_body,mask
from check_deorbit_geometry import Vec,dot,exclude,cross
from check_minmus_kolniya import executable

SOURCE='\n'.join((ROOT/f'lib/{name}.ks').read_text() for name in ('entry_landing_math','entry_landing'))


class Map(dict):
    LENGTH=property(len)
    COPY=property(lambda self:Map(self))
    HASKEY=dict.__contains__
    VALUES=property(lambda self:__import__('check_runtime_contracts').KList(self.values()))


@lru_cache(None)
def prepared(source,name):
    code=function_body(source,name)
    params=[];defaults={}
    for group in re.findall(r'PARAMETER ([^.]+)\.',code):
        for raw in group.split(','):
            fields=raw.strip().split(' IS ');params.append(fields[0])
            if len(fields)>1:
                defaults[fields[0]]={'FALSE':False,'TRUE':True}.get(fields[1],None)
                if defaults[fields[0]] is None:defaults[fields[0]]=float(fields[1])
    code=re.sub(r'PARAMETER [^.]+\.','',code)
    code=re.sub(r'WAIT UNTIL [^.]+\.', 'fixture_settle().', code)
    def strip(nodes):
        rows=[]
        for text,yes,no in nodes:
            if text.startswith(('mLog(','mLogWarn(','mLogError(','mLogSummary(')):text='fixture_log()'
            rows.append((text,strip(yes),strip(no)))
        return rows
    return params,defaults,ks.compile_nodes(ks.freeze(strip(executable(code))))


def call(source,name,env,*args):
    params,defaults,code=prepared(source,name)
    local=dict(env);local.update(defaults);local.update(zip(params,args))
    try:ks.execute(code,local)
    except ks.Returned as result:return result.value


def fixture():
    body=NS(NAME='Duna',MU=3.0136321e11,RADIUS=320000,ATM=NS(EXISTS=True,HEIGHT=50000))
    ship=NS(BODY=body,STATUS='FLYING',MASS=1,AVAILABLETHRUST=12,THRUST=0,
        ALTITUDE=800,VERTICALSPEED=-30,AIRSPEED=30,CURRENTSTAGE=2,
        CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),
        BOUNDS=NS(BOTTOMALTRADAR=800),UP=NS(VECTOR=Vec((0,1,0))),
        VELOCITY=NS(SURFACE=Vec((0,-30,0))),FACING=NS(FOREVECTOR=Vec((0,1,0))),
        PARTS=[NS(HASMODULE=lambda name:name=='ModuleParachute') for _ in range(4)])
    state=dict(phase='SCIENCE_ENTRY',mission_id='duna_lander',launch_time=1000)
    events=[]
    env=dict(SHIP=ship,STAGE=NS(DELTAV=NS(VACUUM=500)),KUNIVERSE=NS(ACTIVEVESSEL=ship),
        ABORT=False,WARP=0,TIME=NS(SECONDS=1100),SAS=False,
        stateGet=state.get,stateGetNum=state.get,
        LEXICON=lambda *xs:Map(zip(xs[::2],xs[1::2])),
        V=lambda *xyz:Vec(xyz),VDOT=dot,VXCL=exclude,VCRS=cross,
        COS=lambda d:math.cos(math.radians(d)),SIN=lambda d:math.sin(math.radians(d)),
        TAN=lambda d:math.tan(math.radians(d)),
        SQRT=math.sqrt,
        VANG=lambda a,b:math.degrees(math.acos(max(-1,min(1,dot(a,b)/(a.MAG*b.MAG))))),
        landingResolveTarget=lambda:Map(FOUND=False),
        fixture_lock=lambda value:events.append(('lock',value)),fixture_unlock=lambda:events.append('unlock'),
        fixture_log=lambda:None,thrustCutoffOk=lambda:events.append('cutoff') or True,
        missionExcursionCommands=lambda:None)
    for key,value in re.findall(r'GLOBAL (\w+) IS ([\d.]+)\.',SOURCE):env[key]=float(value)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:call(SOURCE,name,env,*args)
    return env,ship,state,events


def check_preflight():
    for fault in ('ok','thrust','mass','twr','fuel','no-chutes','config','nan-thrust','nan-fuel','no-tilt-margin'):
        env,ship,_,_=fixture()
        if fault=='thrust':ship.AVAILABLETHRUST=0
        if fault=='mass':ship.MASS=0
        if fault=='twr':ship.AVAILABLETHRUST=2
        if fault=='fuel':env['STAGE'].DELTAV.VACUUM=330
        if fault=='no-chutes':ship.PARTS=[]
        if fault=='config':env['ENTRY_LANDING_REACTION']=-1
        if fault=='nan-thrust':ship.AVAILABLETHRUST=math.nan
        if fault=='nan-fuel':env['STAGE'].DELTAV.VACUUM=math.nan
        if fault=='no-tilt-margin':
            ship.AVAILABLETHRUST=3.6;env.update(ENTRY_LANDING_MIN_TWR=1.21,ENTRY_LANDING_MAX_TILT=30)
        result=env['entryLandingPreflight'](40)
        assert result['OK']==(fault=='ok'),(fault,result)
    print('PASS: actual active-stage fuel pays deorbit plus300m/s terminal reserve; missing chutes, thrust/TWR/tilt authority, nonfinite readings and invalid policy refuse deorbit readiness')


def check_controller_and_live_cutoffs():
    for fault in ('ok','align','stale','pilot','abort','warp','vessel','body','phase','stage','no-thrust','landed'):
        env,ship,state,events=fixture()
        ship.ALTITUDE=100;ship.BOUNDS.BOTTOMALTRADAR=100
        ctx=env['entryLandingCreate']()
        assert env['entryLandingTick'](ctx)
        assert ctx['ACTIVE'] and len([e for e in events if isinstance(e,tuple) and e[0]=='lock'])==2
        assert 0<ctx['COMMAND']<=1
        if fault=='align':ship.FACING.FOREVECTOR=Vec((1,0,0))
        if fault=='stale':env['TIME'].SECONDS+=2
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='abort':env['ABORT']=True
        if fault=='warp':env['WARP']=1
        if fault=='vessel':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='body':ship.BODY=NS(NAME='Ike')
        if fault=='phase':state['phase']='SURFACE_SCIENCE'
        if fault=='stage':ship.CURRENTSTAGE=1
        if fault=='no-thrust':ship.AVAILABLETHRUST=0
        if fault=='landed':ship.STATUS='LANDED'
        throttle=env['entryLandingThrottle'](ctx)
        assert (throttle>0)==(fault=='ok'),(fault,throttle)
    env,ship,state,events=fixture();ctx=env['entryLandingCreate']()
    env['entryLandingTick'](ctx)
    def cutoff():assert ctx['COMMAND']==0;events.append('cutoff');return True
    env['thrustCutoffOk']=cutoff
    assert env['entryLandingStop'](ctx) and not ctx['ACTIVE'] and events[-2:]==['cutoff','unlock']
    # High/fast atmospheric flight stays on its existing entry guidance.
    for altitude,speed in ((30000,100),(5000,900)):
        env,ship,_,events=fixture();ship.BOUNDS.BOTTOMALTRADAR=altitude;ship.ALTITUDE=altitude;ship.AIRSPEED=speed
        ctx=env['entryLandingCreate']()
        assert not env['entryLandingTick'](ctx) and not events and ctx['COMMAND']==0
    assert not re.search(r'(?m)^\s*(?:STAGE|ADD|REMOVE|WAIT)\b',mask(SOURCE))
    print('PASS: arming aligns without a blocking wait; live callback zeros thrust on misalignment, stale commands, takeover/staging/Abort/contact, cutoff precedes release and fast/high entry is left to drag/chutes')


def check_independent_descent():
    outcomes=[]
    for initial_height,initial_down,twr,delay,drag_terminal in ((1200,30,1.5,4,None),(800,60,3,2,None),(700,40,8,8,25)):
        env,_,_,_=fixture()
        mu=3.0136321e11;radius=320000;mass=1.;thrust=twr*mu/radius**2
        height=initial_height;velocity=-initial_down;elapsed=0.;impulse=0.;max_up=0.
        while height>0 and elapsed<1000:
            gravity=mu/(radius+height)**2
            plan=env['entryLandingPlan'](height,max(0,-velocity),thrust/mass,gravity)
            assert plan['OK'] and plan['TARGET_DOWN']>0
            command=min(1,plan['UP_ACC']/(thrust/mass)) if elapsed>=delay else 0.
            drag=0. if drag_terminal is None else -gravity*velocity*abs(velocity)/drag_terminal**2
            acceleration=command*thrust/mass-gravity+drag
            dt=.05
            height+=velocity*dt+.5*acceleration*dt*dt;velocity+=acceleration*dt
            impulse+=command*thrust/mass*dt;mass-=command*thrust/(320*9.80665)*dt
            elapsed+=dt;max_up=max(max_up,velocity)
        outcomes.append((initial_height,twr,round(-velocity,3),round(impulse,1),round(elapsed,1)))
        assert height<=0 and 0<-velocity<3.5 and impulse<300 and max_up<.1,outcomes[-1]
    print('PASS: independent variable-mass gravity/drag integration reaches downward touchdown<3.5m/s with<300m/s impulse and no climb for TWR1.5/3/8 and2..8s alignment delays:',outcomes)


def check_resident_science_and_terminal():
    from check_runtime_contracts import KList
    science=(ROOT/'lib/science_entry.ks').read_text()
    science=science.replace('BRAKES ON.','fixture_brakes().')
    science=science.replace('stateGetNum("launch_time",0)+":"+primary:NAME','fixtureStamp()+":"+primary:NAME')
    for outcome in ('surface','abort','pilot','weak-power'):
        env,ship,state,events=fixture()
        if outcome=='weak-power':
            ship.AVAILABLETHRUST=1;env['ENTRY_LANDING_REQUIRE_POWER']=0
        ship.BOUNDS.BOTTOMALTRADAR=ship.ALTITUDE=100
        ship.PERIAPSIS=5000;ship.ORBIT=NS(HASNEXTPATCH=False)
        samples=[];ticks=[];ctxs=[];start=env['TIME'].SECONDS
        def wait(dt):
            env['TIME'].SECONDS+=dt
            if env['TIME'].SECONDS>=start+1.2:
                if outcome in ('surface','weak-power'):ship.STATUS='LANDED'
                if outcome=='abort':env['ABORT']=True
                if outcome=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.5
        create=env['entryLandingCreate'];tick=env['entryLandingTick']
        def make():ctx=create();ctxs.append(ctx);return ctx
        def control(ctx):ticks.append(env['TIME'].SECONDS);return tick(ctx)
        env.update(ENTRY_POWERED_LANDING=1,ABORT=False,HASNODE=False,
            SCIENCE_ENTRY_BANDS=Map(Duna=KList([140000,12000])),
            SCIENCE_ENTRY_PREPARE_LEAD=180,SCIENCE_ENTRY_MAX_PASSES=3,
            SCIENCE_ENTRY_MIN_EC=.05,SCIENCE_ENTRY_MOON_MIN_PE=20000,SCIENCE_ENTRY_MOON='',SCIENCE_ENTRY_CHUTES=1,
            MISSION_ASSIST_SCIENCE=0,HOMECONNECTION=NS(ISCONNECTED=True),
            missionTargetBody=lambda:ship.BODY,fixture_settle=lambda:None,fixtureStamp=lambda:'1000',
            fixture_wait=wait,fixture_brakes=lambda:events.append('brakes'),
            stateSet=lambda key,value:state.update({key:value}),
            scienceEntrySample=lambda primary:samples.append(env['TIME'].SECONDS),
            _scienceEntryMoonCheck=lambda primary:True,_scienceEntryWakeUt=lambda:env['TIME'].SECONDS,
            aerobrakeApEntryEta=lambda *_:0,shipPowerFraction=lambda:1,
            entryLandingCreate=make,entryLandingTick=control,
            _scienceEntryChutes=lambda primary:events.append('chute-request'),
            yieldToPrompt=lambda:events.append('held'),nextPhase=lambda *_:events.append('advance'),xferSeq=KList())
        env['_scienceEntryHold']=lambda reason:call(science,'_scienceEntryHold',env,reason)
        # Share the top-level globals so asynchronous Abort/pilot changes are
        # observed by both the resident loop and its callback functions.
        try:ks.execute(prepared(science,'phaseScienceEntry')[2],env)
        except ks.Returned:pass
        assert len(samples)>=3 and len(ticks)>=(3 if outcome=='weak-power' else 20) and ctxs
        assert all(b-a<(.51 if outcome=='weak-power' else .06) for a,b in zip(ticks,ticks[1:]))
        assert env['entryLandingThrottle'](ctxs[0])==0
        assert events.count('cutoff')>=2 and 'chute-request' in events
        assert ('advance' in events)==(outcome in ('surface','weak-power'))
        assert ('held' in events)==(outcome=='pilot'),(outcome,events)
        if outcome=='weak-power':
            assert not any(isinstance(e,tuple) and 'LOCK THROTTLE TO entryLandingThrottle' in e[1] for e in events)
    print('PASS: actual science entry keeps20Hz terminal updates beside science/chute requests, cuts thrust before surface dwell/advance and stops on Abort or pilot takeover')


if __name__=='__main__':
    check_preflight()
    check_controller_and_live_cutoffs()
    check_independent_descent()
    check_resident_science_and_terminal()
