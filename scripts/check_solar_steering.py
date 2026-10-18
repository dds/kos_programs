"""Solar attitude geometry, finite-turn control and recorder fixtures; not KSP."""
import math
import re
from types import SimpleNamespace as NS

import numpy as np
import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask, dependency_tables, closure
from check_solar_reuse import environment, run_solar_body, SOURCE, Items
from check_deorbit_geometry import Vec, evaluate

DIAG=(ROOT/'lib/solar_diagnostics.ks').read_text()


class Direction:
    def __init__(self, matrix):self.matrix=np.asarray(matrix)
    def __mul__(self, other):
        if isinstance(other,Direction):return Direction(self.matrix@other.matrix)
        return Vec(self.matrix@other)
    INVERSE=property(lambda self:Direction(self.matrix.T))
    FOREVECTOR=property(lambda self:Vec(self.matrix[:,2]))
    TOPVECTOR=property(lambda self:Vec(self.matrix[:,1]))
    STARVECTOR=property(lambda self:Vec(self.matrix[:,0]))


def rotation(axis, angle):
    axis=np.asarray(axis)/np.linalg.norm(axis)
    xx,yy,zz=axis
    skew=np.array(((0,-zz,yy),(zz,0,-xx),(-yy,xx,0)))
    return Direction(np.eye(3)+math.sin(angle)*skew+(1-math.cos(angle))*(skew@skew))


def from_to(first,second):
    first,second=first/np.linalg.norm(first),second/np.linalg.norm(second)
    axis=np.cross(first,second)
    if np.linalg.norm(axis)<1e-10:
        if np.dot(first,second)>0:return Direction(np.eye(3))
        axis=np.cross(first,np.eye(3)[np.argmin(np.abs(first))])
    return rotation(axis,math.acos(np.clip(np.dot(first,second),-1,1)))


def angle(first,second):
    return math.degrees(math.acos(np.clip(np.dot(first,second)/np.linalg.norm(first)/np.linalg.norm(second),-1,1)))


def attitude_environment():
    env,*rest=environment()
    env.update(ROTATEFROMTO=from_to,VANG=angle,LEXICON=lambda *xs:dict(zip(xs[::2],xs[1::2])),
               fixture_lock=lambda _:None)
    env['SHIP'].FACING=Direction(np.eye(3))
    env['SHIP'].ANGULARVEL=Vec((0,0,0))
    env['_solarAimDirection']=lambda aim:ks.call('_solarAimDirection',env,aim)
    return env,rest


def check_anchored_target():
    rng=np.random.default_rng(621)
    for _ in range(30):
        env,_=attitude_environment()
        env['aShip']=Vec(rng.normal(size=3)).NORMALIZED
        env['SHIP'].FACING=rotation(rng.normal(size=3),rng.uniform(-math.pi,math.pi))
        env['SUN'].POSITION=Vec(rng.normal(size=3))*1e10
        aim=run_solar_body('_solarAim',env)
        first=env['_solarAimDirection'](aim)
        assert angle(first*env['aShip'],env['SUN'].POSITION)<1e-5
        for _ in range(3):
            # A requested complete attitude must not chase changes in the
            # vessel's actual orientation (including roll about the Sun).
            env['SHIP'].FACING=rotation(rng.normal(size=3),rng.uniform(-math.pi,math.pi))
            assert np.allclose(env['_solarAimDirection'](aim).matrix,first.matrix)
        env['SUN'].POSITION=Vec(rng.normal(size=3))*1e10
        assert angle(env['_solarAimDirection'](aim)*env['aShip'],env['SUN'].POSITION)<1e-5
    assert 'SHIP:FACING' not in function_body(SOURCE,'_solarAimDirection')
    assert 'tracking-probe' not in function_body(SOURCE,'_solarOrient')
    print('PASS: 30 arbitrary panel/ship frames point the chosen axis at the live Sun; target does not chase vessel attitude or roll')


def check_finite_six_axis_search():
    for normal in (Vec((1,0,0)),Vec((0,-1,0)),Vec((0,0,1)),Vec((.35,.9,-.25)).NORMALIZED,
                   Vec((.55,.61,.57)).NORMALIZED):
        env,rest=attitude_environment()
        saved,attempts,finishes,unlocked,reading=rest
        env['SHIP'].FACING=rotation((.2,.8,.3),1.1)
        env['SUN'].POSITION=Vec((.3,.4,.8))*1e10
        mount=rotation((.6,-.3,.2),.8)
        class Panel:
            FACING=property(lambda _:env['SHIP'].FACING*mount)
            HASMODULE=staticmethod(lambda _:True)
            GETMODULE=staticmethod(lambda _:NS(HASFIELD=lambda _:True))
        env['SHIP'].PARTS=Items([Panel()])
        env['shipSolarFlow']=lambda:10*max(0,float(np.dot(
            env['SHIP'].FACING*(mount*normal),env['SUN'].POSITION.NORMALIZED)))
        active=[None]
        def aim(axis):
            attempts.append(axis)
            active[0]=ks.call('_solarAim',env,axis)
            return active[0]
        def wait(dt):
            env['TIME'].SECONDS+=dt
            desired=env['_solarAimDirection'](active[0])
            delta=desired.matrix@env['SHIP'].FACING.matrix.T
            radians=math.acos(np.clip((np.trace(delta)-1)/2,-1,1))
            if radians<1e-7:
                env['SHIP'].FACING=desired
                env['SHIP'].ANGULARVEL=Vec((0,0,0))
                return
            vals,vecs=np.linalg.eig(delta)
            axis=np.real(vecs[:,np.argmin(np.abs(vals-1))])
            skew=Vec((delta[2,1]-delta[1,2],delta[0,2]-delta[2,0],delta[1,0]-delta[0,1]))
            if np.dot(axis,skew)<0:axis=-axis
            turn=min(radians,.6*dt)
            env['SHIP'].FACING=rotation(axis,turn)*env['SHIP'].FACING
            env['SHIP'].ANGULARVEL=Vec(axis*turn/dt)
        env.update(_solarAim=aim,fixture_wait=wait)
        env['_solarAimSettle']=lambda *args:ks.call('_solarAimSettle',env,*args)
        env['_solarRefine']=lambda *args:ks.call('_solarRefine',env,*args)
        assert ks.call('orientForSolar',env,True,True,True)
        assert 12<=len(attempts)<=13 and finishes[-1][2]=='best of 6'
        assert env['shipSolarFlow']()>9.99 and env['TIME'].SECONDS<60
        assert env['CONFIG'].IPU==150
    print('PASS: actual coarse/refine/hold source reaches >99.9% flow with finite 3D turns for axis-aligned, tilted and diagonal panel normals')


def check_scope_and_warp_release():
    for prior in (150,2000):
        for result in (True,False):
            env,saved,*_=environment()
            env['CONFIG'].IPU=prior
            env['LOG_ARCHIVE_DEFERRED']=3
            def search(*_):
                assert env['CONFIG'].IPU==2000 and env['LOG_ARCHIVE_DEFERRED']==1
                return result
            env['_solarOrient']=search
            env.update(forceSearch=False,lockSteering=True,overrideLaunchGuard=True,deadlineUt=0)
            assert run_solar_body('orientForSolar',env)==result
            assert env['CONFIG'].IPU==prior and env['LOG_ARCHIVE_DEFERRED']==3
            assert 'solar_prior_ipu' not in saved
    boot=(ROOT/'lib/boot_lib.ks').read_text()
    env,saved,*_=environment()
    saved['solar_prior_ipu']=150
    env.update(bootLibLoad=lambda _:None)
    env['CONFIG'].IPU=2000
    run_solar_body_from=function_body(boot,'bootPreamble')
    ks.run(ks.parse(run_solar_body_from),env)
    assert env['CONFIG'].IPU==150 and 'solar_prior_ipu' not in saved
    for settled,abort in ((False,False),(False,True),(True,False)):
        env,*_=environment()
        env.update(forceSearch=True,lockSteering=True,deadlineUt=10,WARP=4,ABORT=abort)
        env['KUNIVERSE'].TIMEWARP.ISSETTLED=settled
        def tick(dt):
            env['TIME'].SECONDS+=dt
            assert env['WARP']==0
            if env['TIME'].SECONDS>=.1:env['KUNIVERSE'].TIMEWARP.ISSETTLED=True
        old=env['_solarAimSettle']
        def aim(*args):
            assert env['WARP']==0 and env['KUNIVERSE'].TIMEWARP.ISSETTLED
            return old(*args)
        env.update(fixture_wait=tick,_solarAimSettle=aim)
        assert run_solar_body('_solarOrient',env)==(not abort)
    print('PASS: success/failure restore CPU/log settings; reboot restores an interrupted CPU floor; no search under warp or operator abort')


class Text(str):
    def __add__(self, other):return Text(str(self)+str(other))
    LENGTH=property(len)
    def CONTAINS(self, value):return value in self
    def STARTSWITH(self, value):return self.startswith(value)


class TraceItems(list):
    LENGTH=property(len)
    ADD=list.append
    def REMOVE(self,index):self.pop(index)


class Lex(dict):
    def HASKEY(self,key):return key in self


def diagnostic_fixture():
    env,_=attitude_environment()
    saved,disk,ops={}, {}, []
    env['SHIP'].NAME='RO9';env['SHIP'].BODY=NS(NAME='Minmus')
    env['SHIP'].PARTS=[];env['SHIP'].THRUST=0
    env['SHIP'].CONTROL=NS(PITCH=.2,YAW=0,ROLL=-.1,MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    env['STEERINGMANAGER']=NS(ENABLED=True,TARGET=Direction(np.eye(3)),PITCHERROR=90,YAWERROR=0,ROLLERROR=0,
                             MAXSTOPPINGTIME=2,ROLLCONTROLANGLERANGE=5,PITCHTS=2,YAWTS=2,ROLLTS=2)
    env['CONFIG'].SUPPRESSAUTOPILOT=False
    env.update(SOLAR_DIAGNOSTICS=1,solarTrace=Lex(),SAS=False,RCS=False,
               CORE=NS(VOLUME=NS(FREESPACE=0)),HOMECONNECTION=NS(ISCONNECTED=False),
               LOG_FILE_RESERVE_BYTES=1024,CHAR=lambda value:Text(chr(value)),
               LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),LIST=lambda *xs:TraceItems(xs),
               fixture_text=Text,fixture_print=lambda _:None,
               codeVersion=lambda:Text('fixture'),slug=lambda:Text('RO9'),
               stateGet=saved.get,stateGetNum=saved.get,
               stateSet=lambda key,value:saved.update({key:value}),
               localFlightLogDir=lambda:Text('1:/run/logs/RO9'),
               fixture_processors=lambda rows:rows.append(NS(TAG='core',MODE='READY',PART=NS(NAME='core'))))
    def disk_op(op,path):
        if path.startswith('0:/'):assert env['HOMECONNECTION'].ISCONNECTED
        ops.append((op,path))
    def exists(path):
        disk_op('exists',path)
        return path in disk
    def mkdir(path):
        disk_op('mkdir',path);disk[path]=Text('')
    def write(payload,path):
        disk_op('write',path);disk[path]=Text(disk.get(path,'')+payload+'\n')
    def opening(path):
        disk_op('read',path)
        return NS(READALL=NS(STRING=disk[path]))
    env.update(EXISTS=exists,CREATEDIR=mkdir,append_payload=write,OPEN=opening)
    def invoke(name,*args):
        src=function_body(DIAG,name).replace('LOG payload TO dest.','append_payload(payload,dest).')
        src=src.replace('LIST PROCESSORS IN processors.','fixture_processors(processors).')
        src=re.sub(r'\bPRINT (.*?)\.\s*\n',r'fixture_print(\1).\n',src,flags=re.S)
        src=re.sub(r'"[^"\n]*"',lambda item:'fixture_text('+item[0]+')',src)
        # Only Begin assigns the module-global recorder. Other function
        # locals remain isolated and mutate its shared lexicon, as in kOS.
        local=env if name=='solarDiagnosticBegin' else dict(env)
        local.update(zip(re.findall(r'PARAMETER (\w+)',src),args))
        try:ks.run(ks.parse(src),local)
        except ks.Returned as returned:return returned.value
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',DIAG):
        env[name]=lambda *args,name=name:invoke(name,*args)
    env['solarDiagnosticBegin'](False,0,150)
    return env,saved,disk,ops


def check_diagnostic_capture():
    env,saved,disk,ops=diagnostic_fixture()
    axis=Vec((1,0,0))
    env['solarDiagnosticSample']('fixed-2','turning',axis,Direction(np.eye(3)))
    row=env['solarTrace']['LAST']
    for field in ('label=fixed-2','axis=','rate=','face=','top=','want=','wantTop=',
                  'managerAim=','managerTop=','errors=','rawCommand=','suppress=',
                  'ipu=','warpSettled=','charge=','flow=','rawThrottle='):
        assert field in row,field
    assert not ops and not saved,'sampling cannot perform disk I/O'
    manager=env['STEERINGMANAGER']
    env['STEERINGMANAGER']=NS(ENABLED=False,PITCHERROR=0,YAWERROR=0,ROLLERROR=0)
    env['solarDiagnosticSample']('fixed-2','turning',axis,Direction(np.eye(3)))
    assert 'managerAim=inactive' in env['solarTrace']['LAST']
    env['STEERINGMANAGER']=manager
    for _ in range(400):env['_solarTraceRow'](Text('x'*1000))
    trace=env['solarTrace']
    assert trace['BYTES']<=24000 and len(trace['ROWS'])<=64 and trace['DROPPED']>0
    env['solarDiagnosticSample']('fixed-2','alignment-timeout',axis,Direction(np.eye(3)))
    env['solarDiagnosticFinish'](False,0)
    assert 'alignment-timeout' in saved['last_solar_summary'] and trace['PENDING'] and not ops
    for name,value in (('THRUST',.1),('THRUST',math.nan),('MAINTHROTTLE',.1),('PILOTMAINTHROTTLE',.1)):
        obj=env['SHIP'] if name=='THRUST' else env['SHIP'].CONTROL
        setattr(obj,name,value)
        assert not env['solarDiagnosticExport'](0) and not ops
        setattr(obj,name,0)
    env['ABORT']=True
    assert not env['solarDiagnosticExport'](0) and not ops
    env['ABORT']=False
    assert not env['solarDiagnosticExport'](10) and not ops
    for linked in (False,True):
        current,state,files,calls=diagnostic_fixture()
        current['solarDiagnosticSample']('fixed-2','alignment-timeout',axis,Direction(np.eye(3)))
        current['solarDiagnosticFinish'](False,0)
        current['HOMECONNECTION'].ISCONNECTED=linked
        current['CORE'].VOLUME.FREESPACE=50000
        assert current['solarDiagnosticExport'](0)
        dest=state['last_solar_report']
        assert dest.startswith('0:/logs/archive/_diagnostics/' if linked else '1:/run/logs/')
        assert all(item in files[dest] for item in ('schema=2','algorithm=anchored-six-axis-refine',
                   'CPU tag=core','status=alignment-timeout','complete','success=False'))
        assert any(op=='read' for op,_ in calls) and not current['solarTrace']['PENDING']
    current,state,files,calls=diagnostic_fixture()
    current['solarDiagnosticSample']('fixed-2','turning',axis,Direction(np.eye(3)))
    current['solarDiagnosticFinish'](False,0)
    current['HOMECONNECTION'].ISCONNECTED=True
    current['OPEN']=lambda _:NS(READALL=NS(STRING=Text('truncated report')))
    assert not current['solarDiagnosticExport'](0) and current['solarTrace']['PENDING']
    assert 'last_solar_report' not in state,'a truncated export is not verified'
    current['HOMECONNECTION'].ISCONNECTED=False
    def mkdir_then_disconnect(path):
        files[path]=Text('')
        current['HOMECONNECTION'].ISCONNECTED=False
    current['HOMECONNECTION'].ISCONNECTED=True
    files.clear();current['CREATEDIR']=mkdir_then_disconnect
    assert not current['solarDiagnosticExport'](0) and current['solarTrace']['PENDING']
    sampler=mask(function_body(DIAG,'solarDiagnosticSample'))
    assert not re.search(r'\b(LOG|WAIT|LOCK|UNLOCK|stateSet)\b',sampler)
    assert not re.search(r'\b(STAGE|DOEVENT|DOACTION|SETFIELD)\b',mask(DIAG))
    assert not re.search(r'\bSET (?:SHIP|STEERINGMANAGER|CONFIG)\b',mask(DIAG))
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'solar_diagnostics' in closure(['solar'],deps)
    for filename,name in (('cmd/solarhold.ks','_cmdSolarhold'),('cmd/orientForSolar.ks','_cmdOrientForSolar')):
        entry=function_body((ROOT/filename).read_text(),name)
        assert entry.index('IF NOT orientForSolar(')<entry.index('solarMaintainHold(')
        assert 'LOCK STEERING TO LOOKDIRUP(SHIP:FACING' not in entry
    print('PASS: recorder captures target/control/CPU/power evidence without sampling I/O; bounded data and summary survive failure; quiet verified archive/offline exports respect deadline, thrust and space')


def check_measurement_ledger():
    env,saved,disk,ops=diagnostic_fixture()
    axis=Vec((1,0,0))
    env['solarDiagnosticSample']('fixed-5','settled',axis,Direction(np.eye(3)))
    measurement=env['solarTrace']['MEASUREMENTS'][0]
    assert 'label=fixed-5' in measurement and 'actualSunAxis=1.0,0.0,0.0' in measurement
    for _ in range(400):env['_solarTraceRow'](Text('x'*1000))
    trace=env['solarTrace']
    assert all('label=fixed-5' not in row for row in trace['ROWS'])
    assert trace['MEASUREMENTS']==[measurement] and not ops and not saved
    for index in range(30):
        env['solarDiagnosticSample']('refine-'+str(index),'settled',axis,Direction(np.eye(3)))
    assert len(trace['MEASUREMENTS'])==24 and 'label=refine-6 ' in trace['MEASUREMENTS'][0]
    assert 'label=refine-29 ' in trace['MEASUREMENTS'][-1]
    retained=trace['MEASUREMENTS'][0]
    for _ in range(400):env['_solarTraceRow'](Text('x'*1000))
    assert retained in trace['MEASUREMENTS'] and all('refine-6 ' not in row for row in trace['ROWS'])
    assert not ops,'measurement ledger remains in RAM until quiet export'
    env['solarDiagnosticFinish'](True,0)
    env['HOMECONNECTION'].ISCONNECTED=True
    assert env['solarDiagnosticExport'](0)
    report=disk[saved['last_solar_report']]
    assert retained in report and 'actualSunAxis=' in report
    assert report.count('STATS solar-diag measured ')==24
    print('PASS: independent 24-measurement ledger preserves coarse/fine comparisons through detail-ring eviction and verified export without sampling I/O')


if __name__=='__main__':
    check_anchored_target()
    check_finite_six_axis_search()
    check_scope_and_warp_release()
    check_diagnostic_capture()
    check_measurement_ledger()
