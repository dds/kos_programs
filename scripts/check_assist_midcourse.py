"""Execute opt-in midpoint preview and handoff source; synthetic conics, not KSP."""
import ast
import re
from functools import lru_cache
from types import SimpleNamespace as NS
import check_landing_guidance as ks
import check_assist_preview as preview
import check_assist_search as search
import check_midcourse as mid
from check_codebase import ROOT,function_body,dependency_tables,closure,mask,command_entrypoint_errors
from check_espoir_fleet import Map,Items
from check_minmus_kolniya import executable

SOURCE=(ROOT/'lib/assist_midcourse.ks').read_text()


@lru_cache(None)
def prepared(name):
    source=function_body(SOURCE,name)
    params=re.findall(r'PARAMETER (\w+)',source)
    defaults={k:ast.literal_eval(v.title()) for k,v in re.findall(r'PARAMETER (\w+) IS (FALSE|TRUE)\.',source)}
    if name=='previewMidcourseAssist':
        nested=function_body(SOURCE,'direct')
        source=source.replace('LOCAL FUNCTION direct {'+nested+'}','').replace('direct@','DIRECT')
    source=re.sub(r'\bDEFINED (\w+)',r'fixture_defined("\1")',source)
    source=source.replace('ADD nd.','fixture_add(nd).').replace('REMOVE nd.','fixture_remove(nd).')
    def instrument(nodes):
        rows=[]
        for text,yes,no in nodes:
            if text.startswith('diagnosticArchiveLine('):
                label='elapsed' if 'candidateInstalled=False' in text else ('header' if 'originalAxes=' in text else 'policy')
                text='fixture_row("'+label+'")'
            if text.startswith(('mLog(','mLogSummary(','mLogError(')):text='fixture_row("log")'
            rows.append((text,instrument(yes),instrument(no)))
        return rows
    return params,defaults,ks.compile_nodes(ks.freeze(instrument(executable(source))))


def call(name,env,*args):
    params,defaults,code=prepared(name)
    local=dict(env);local.update(defaults);local.update(zip(params,args))
    try:ks.execute(code,local)
    except ks.Returned as result:return result.value


def fixture(seeded=False):
    env,nd,route,_,_,state,world,events,trace,fallback=preview.fixture()
    target=env['assistRouteBodies'](route)[-1]
    state['vehicle']='Espoir'
    rows=[];results=[];created=[];removed=[]
    env.update(ASSIST_MIDCOURSE_PREVIEW=1,MISSION_ASSIST_ROUTE=route,
        ASSIST_RESERVE_DV=120,CAPTURE_RESERVE_DV=150,SOI_BUFFER_TIME=120,
        HOMECONNECTION=NS(ISCONNECTED=True),phaseShouldYield=False,
        missionTypeDetect=lambda:'interplanetary',arrivalCorrectionLead=lambda duration:max(300,duration/2+150),
        assistPreviewMissionFallback=lambda:fallback,configLiteral=str,
        stateSet=lambda key,val:state.update({key:val}),
        diagnosticArchiveOpen=lambda _:Map(READY=True,COMPLETE=True,PATH='0:/preview.log'),
        diagnosticArchiveLine=lambda report,row:rows.append(row),
        diagnosticArchiveClose=lambda *_:True,fixture_row=rows.append,
        mLog=rows.append,mLogSummary=rows.append,mLogError=rows.append)
    def hold():env['phaseShouldYield']=True
    env['yieldToPrompt']=hold
    env['fixture_defined']=env.__contains__
    for name in ('_assistMidcourseBound','_assistMidcourseHold','previewMidcourseAssist'):
        env[name]=lambda *args,name=name:call(name,env,*args)
    def report(result,report_state):
        results.append(result)
    env['assistPreviewResult']=report
    env['assistPreviewPatchRows']=lambda *_:rows.append('patches')
    env['DIRECT']=NS(CALL=lambda node,goal,budget:env['assistPreviewDirect'](node,goal,budget,fallback))
    def make(epoch,radial,normal,prograde):
        node=type(nd)();node.TIME=epoch;node.RADIALOUT=radial;node.NORMAL=normal;node.PROGRADE=prograde
        created.append(node);return node
    def add(node):
        env['ALLNODES'].append(node);env['NEXTNODE']=node;env['HASNODE']=True
    def remove(node):
        removed.append(node);env['ALLNODES'].remove(node)
        env['HASNODE']=bool(env['ALLNODES'])
    env.update(NODE=make,fixture_add=add,fixture_remove=remove)
    if seeded:env['HASNODE']=False;env['ALLNODES'].clear()
    return env,nd,target,state,world,rows,results,created,removed


def check_actual_search_and_seed():
    for seeded in (False,True):
        env,nd,target,state,world,rows,results,created,removed=fixture(seeded)
        before=(nd.TIME,nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)
        assert env['previewMidcourseAssist'](target,0 if seeded else nd)
        assert results and results[0]['RESTORED'] and results[0]['TRIALS']>1
        assert state['assist_mcc_preview']['status']=='done' and not env['phaseShouldYield']
        assert 'elapsed' in rows and 'header' in rows
        assert 'candidateInstalled=False' in SOURCE and 'originalAxes=' in SOURCE
        if seeded:
            assert len(created)==1 and removed==created and not env['HASNODE']
        else:
            assert not created and not removed and (nd.TIME,nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==before
            assert results[0]['OK'] # A real synthetic candidate is reported, never installed.
        count=len(results)
        assert env['previewMidcourseAssist'](target,0 if seeded else nd)
        assert len(results)==count # Reboot/checkpoint repeats use the saved binding.
    print('PASS: actual search reports/restores a synthetic candidate without adopting it; zero-dV seeds also search and are removed, and the persisted per-leg marker prevents repeated work')


def check_skips_and_takeover():
    for fault in ('disabled','offline','moon','wrong-phase','late','duration','no-route','unsupported','warp','budget','retry',
                  'incomplete-header','edit-during-search','edit-during-close','vessel-during-close','abort','pending'):
        env,nd,target,state,world,rows,results,created,removed=fixture()
        if fault=='disabled':env['ASSIST_MIDCOURSE_PREVIEW']=0
        if fault=='offline':env['HOMECONNECTION'].ISCONNECTED=False
        if fault=='moon':target.BODY.HASBODY=True
        if fault=='wrong-phase':state['phase']='BPLANE'
        if fault=='late':nd.TIME=1100
        if fault=='duration':env['arrivalBurnSeconds']=lambda _: -1
        if fault=='no-route':env['MISSION_ASSIST_ROUTE']=Items()
        if fault=='unsupported':env['assistPreviewMissionFallback']=lambda:Map()
        if fault=='warp':env['WARP']=1
        if fault=='retry':state['bplane_retry_wait']=Map(checkpoint='final')
        if fault=='budget':
            real=env['searchAssistNode']
            def expired(*args):
                result=real(*args);result.update(OK=False,CANCELLED=True,STOP='game-deadline');return result
            env['searchAssistNode']=expired
        if fault=='incomplete-header':env['diagnosticArchiveOpen']=lambda _:Map(READY=True,COMPLETE=False,PATH='0:/preview.log')
        if fault=='edit-during-search':
            real=env['searchAssistNode']
            def changed(*args):
                result=real(*args);nd.NORMAL+=.1;return result
            env['searchAssistNode']=changed
        if fault=='edit-during-close':env['diagnosticArchiveClose']=lambda *_:setattr(nd,'NORMAL',77)
        if fault=='vessel-during-close':env['diagnosticArchiveClose']=lambda *_:setattr(env['KUNIVERSE'],'ACTIVEVESSEL',NS())
        if fault=='abort':env['ABORT']=True
        if fault=='pending':
            state['assist_mcc_preview']=Map(mission=state['mission_id'],launch=state['launch_time'],
                vehicle='Espoir',target=target.NAME,status='started')
            env['ASSIST_MIDCOURSE_PREVIEW']=0 # Disabling cannot bypass interrupted ownership.
        outcome=env['previewMidcourseAssist'](target,nd)
        held=fault in ('edit-during-search','edit-during-close','vessel-during-close','pending')
        assert env['phaseShouldYield']==held,(fault,rows)
        assert outcome==(not held and fault!='abort'),(fault,rows)
        assert not created and not removed
        if fault.startswith('edit-'):assert nd.NORMAL!=0
        if fault not in ('edit-during-search','edit-during-close','vessel-during-close','budget'):
            assert not results
    # Context changes during persistent marker I/O precede any seed mutation.
    env,nd,target,state,world,rows,results,created,removed=fixture(True)
    setter=env['stateSet']
    def change(key,val):setter(key,val);env['KUNIVERSE'].ACTIVEVESSEL=NS()
    env['stateSet']=change
    assert not env['previewMidcourseAssist'](target,0) and not created and not removed
    print('PASS: disabled/offline/late/unpriced contexts skip without nodes; interruption or search/report/persistence takeover holds without deleting or overwriting foreign state')


def check_phase_order_and_loading():
    for branch in ('correction','already','stale','minimum','blocked'):
        env,state,events,alarms,target,hit=mid.retry_environment()
        state['phase']='REFINE_BPLANE'
        env.update(ASSIST_HAS_MIDCOURSE_PREVIEW=True,MAX_BURNS=1,REFINE_BPLANE_MAX_BURNS=1)
        node=NS()
        pristine=[branch in ('already','stale')]
        def probe(body,nd,check_only):
            events.append(('preview',nd,check_only))
            if not check_only and branch=='stale':pristine[0]=False
            return branch!='blocked'
        env['previewMidcourseAssist']=probe
        env['_bplaneCurrentCorridorOk']=lambda *_:pristine[0]
        env['measureArrival']=lambda *_:dict(pe=15000,inc=90,lan=0)
        env['_bplaneCorridorError']=lambda *_:dict(peErr=0,planeErr=0)
        env['_bplaneCorridorOk']=lambda *_:False
        def plan(*_):
            events.append(('plan',));env['_bplaneMinimumSkip']['ACCEPTED']=branch=='minimum'
            return 0 if branch=='minimum' else node
        env['planBplaneCorrection']=plan
        env['_bplaneFinishMinimumSkip']=lambda *_:True
        env['bplaneCorrectionAllowed']=lambda *_:events.append(('admit',)) or True
        env['_bplaneReserveCorrection']=lambda *_:events.append(('reserve',))
        env['_bplaneClearCoastTimes']=lambda:None
        env['_bplaneExecuteCorrection']=lambda:events.append(('burn',)) or True
        env['_bplaneSafeEncounter']=lambda *_:True
        env['bplaneArrivalStatus']=lambda:None
        mid.run(function_body(mid.SOURCE,'phaseRefineBplane'),env)
        assert events[0]==('preview',0,True),(branch,events)
        if branch in ('correction','stale'):
            labels=[row[0] for row in events]
            plan_index=labels.index('plan')
            assert plan_index<labels.index('preview',plan_index)<labels.index('admit')<labels.index('reserve')<labels.index('burn')
        elif branch in ('already','minimum'):
            assert ('preview',0,False) in events and not any(row[0]=='burn' for row in events)
        else:assert len(events)==1
    source=(ROOT/'lib/mission_type.ks').read_text()
    body=function_body(source,'missionTypeConditionalRoots')
    for enabled,phase,kind,pending,expected in ((0,'XFER_BPLANE','interplanetary',False,False),
            (1,'XFER_BPLANE','interplanetary',False,True),(1,'XFER_PLAN','interplanetary',False,False),
            (1,'XFER_BPLANE','kerbin_moon',False,False),(0,'XFER_BPLANE','interplanetary',True,True)):
        env=dict(bandKey=phase,ASSIST_MIDCOURSE_PREVIEW=enabled,MISSION_ASSIST_SCIENCE=0,
            missionTypeDetect=lambda:kind,stateGet=lambda *_:Map(status='started' if pending else 'done'),
            LIST=lambda *xs:Items(xs),LEXICON=lambda *xs:Map(),SEQUENCE=Items(),RENDEZVOUS_TARGET='',ASTEROID_TARGET='')
        try:ks.run(executable(body),env)
        except ks.Returned as result:roots=result.value
        assert ('assist_midcourse' in roots)==expected
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert {'assist_search','assist_search_native','assist_preview','diagnostic_log'}<=closure(['assist_midcourse'],deps)
    assert 'assist_midcourse' not in closure(phases['refine_bplane'],deps)
    assert not command_entrypoint_errors((ROOT/'cmd/assistmcc.ks').read_text())
    assert not re.search(r'\b(?:executeManeuver|CREATEALARM|DELETEALARM|missionOverrideUpdate)\s*\(|(?m:^\s*(?:STAGE|LOCK|UNLOCK|SET WARP)\b)',mask(SOURCE))
    print('PASS: actual REFINE hooks run before fresh admission/reserve/burn, cover pristine/minimum skips and block interrupted entry; heavy helpers load only for opted-in interplanetary refinement, with no new alarms or propulsion path')


def check_operator_flag():
    command=(ROOT/'cmd/assistmcc.ks').read_text()
    code=function_body(command,'_cmdAssistmcc')
    for flag,mission,expected in ((0,'test',0),(1,'test',1),(2,'test',None),(1,'',None)):
        changes=[]
        env=dict(enabled=flag,RUNPATH=lambda *_:None,bootPreamble=lambda:None,
            stateGet=lambda *_:mission,missionOverrideUpdate=changes.append,
            LEXICON=lambda *xs:Map(zip(xs[::2],xs[1::2])))
        try:ks.run(executable(code),env)
        except ks.Returned:pass
        assert changes==([] if expected is None else [Map(ASSIST_MIDCOURSE_PREVIEW=expected)])
    arrival=(ROOT/'cmd/arrival.ks').read_text()
    action=function_body(arrival,'_arrivalCommand')
    assert action.index('IF action = "replan"')<action.index('stateRemove("assist_mcc_preview")')<action.index('UNTIL NOT HASNODE')
    print('PASS: enable/disable writes only its override, invalid/no-mission inputs do nothing, and explicit arrival replan clears the interrupted-preview marker before discarding/replanning nodes')


if __name__=='__main__':
    check_actual_search_and_seed()
    check_skips_and_takeover()
    check_phase_order_and_loading()
    check_operator_flag()
