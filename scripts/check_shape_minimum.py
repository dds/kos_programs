"""SHAPE minimum across all candidate/retry paths; not a native kOS run."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT,function_body

SOURCE=(ROOT/'lib/orbit_shape.ks').read_text()


class Lex(dict):
    LENGTH=property(len)
    HASKEY=dict.__contains__
    ISTYPE=lambda self,name:name=='Lexicon'


class Skip(str):
    ISTYPE=lambda self,name:False


def execute(name,env):
    source=re.sub(r'PARAMETER [^.]+\.', '',function_body(SOURCE,name))
    source=source.replace('REMOVE nd.','fixture_remove(nd).')
    source=source.replace('REMOVE NEXTNODE.','fixture_remove(NEXTNODE).')
    def strip(nodes):
        return [(text,strip(yes),strip(no)) for text,yes,no in nodes if not text.startswith('PRINT ')]
    try:ks.run(strip(ks.parse(source)),env)
    except ks.Returned as result:return result.value


def fixture():
    removed=[];events=[]
    env=dict(SHAPE_MIN_BURN_DV=.4,_shapeMinimumSkipped=False,
        SHAPE_BURN_TOLERANCE=-1,BURN_TRIM_ABS_COMPLETE_DV=.05,BURN_TRIM_COMPLETE_MAX_DV=.05,
        _shapeInterruptedHold=lambda _:False,
        _peFloor=lambda:9000,
        SHAPE_ALT_TOL=250,SHAPE_ANG_TOL=.1,SHAPE_AOP_TOL=.2,
        NEAR_CIRC_ECC=.01,MIN_AOP_TARGET_ECC=.004,
        SHIP=NS(PERIAPSIS=9300,APOAPSIS=410000,ALTITUDE=100000,
            ORBIT=NS(INCLINATION=63.4,LAN=79.2,ECCENTRICITY=.65,PERIOD=20000)),
        ETA=NS(PERIAPSIS=1000,APOAPSIS=14000),HASNODE=False,
        WARP=0,ABORT=False,KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)))
    def remove(node):
        removed.append(node);env['HASNODE']=False
    env.update(fixture_remove=remove,fixture_wait=lambda dt:events.append(('wait',dt)),
        LEX=lambda *xs:Lex(zip(xs[::2],xs[1::2])),LEXICON=lambda:Lex())
    # Keep the shared flag and node-removal primitives visible across calls,
    # as the native library's captured file scope is in the real program.
    def above(node,label):
        local=dict(env,nd=node,label=label)
        result=execute('_shapeNodeAboveMinimum',local)
        env['_shapeMinimumSkipped']=local['_shapeMinimumSkipped']
        return result
    env['_shapeNodeAboveMinimum']=above
    env['_shapePlanningReady']=lambda:execute('_shapePlanningReady',env)
    env['_shapeNodeTimingReady']=lambda node:execute('_shapeNodeTimingReady',dict(env,nd=node))
    return env,removed,events


def check_all_final_nodes():
    for label in ('plane','aop','set-ap','set-pe','placed-pe','placed-ap'):
        for dv,accepted in ((0,False),(.1,False),(.3999,False),(.4,True),(1,True),(math.nan,False)):
            env,removed,events=fixture()
            node=NS(DELTAV=NS(MAG=dv),ETA=14400)
            assert env['_shapeNodeAboveMinimum'](node,label)==accepted
            assert removed==([] if accepted else [node])
            assert not events # No alarm, budget, wait, burn or retry.
            assert env['_shapeMinimumSkipped']==(not accepted)
    env,removed,_=fixture();env['SHAPE_MIN_BURN_DV']=.05
    assert env['_shapeNodeAboveMinimum'](NS(DELTAV=NS(MAG=.1)),'plane')
    assert not removed # Explicitly configured finer control still works.
    print('PASS: shared SHAPE minimum rejects0.1m/s plane/AoP/apsis nodes before any4h wait or budget charge, preserves0.4m/s boundary and rejects zero/nonfinite dV')


def check_refinement_cannot_bypass():
    for label in ('aop','set-ap','set-pe'):
        env,removed,events=fixture();node=NS(DELTAV=NS(MAG=2),TIME=14400,ETA=14400,
            RADIALOUT=0,NORMAL=0,PROGRADE=2,ORBIT=NS())
        def refine(*_):node.DELTAV.MAG=.1;return 0
        env.update(nd=node,label=label,targets=Lex(),
            _refineBurnNode=refine,_nodeUnsafe=lambda _:False,_nodeWrecksPlane=lambda _:False)
        finish=function_body(SOURCE,'_finishShapeNode').replace('REMOVE nd.','fixture_remove(nd).')
        # Execute the real finisher with the shared predicate; only its
        # numerical optimizer response is modeled here.
        finish=re.sub(r'PARAMETER [^.]+\.', '',finish)
        try:ks.run(ks.parse(finish),env)
        except ks.Returned as result:assert result.value=='skip'
        else:raise AssertionError('tiny refined node was retained')
        assert removed==[node] and env['_shapeMinimumSkipped']
    print('PASS: a2m/s analytic seed refined down to0.1m/s is removed at final admission for AoP and both apsides; early seed-only minimum cannot be bypassed')


def check_tiny_plane_allows_useful_apsis():
    env,removed,events=fixture();tiny=NS(DELTAV=NS(MAG=.1),ETA=14400)
    useful=NS(DELTAV=NS(MAG=1))
    errs=Lex(PLANE=.2,AP=12728,PE=0,AOP=0)
    targets=Lex(INC=63.4,LAN=79.2,AP=397272,PE=9300,AOP=90)
    env.update(targets=targets,shapeErrors=lambda _:errs,
        planPlaneMatch=lambda *_:tiny,_apsisBurn=lambda *args:Lex(node=useful,label=args[3]))
    result=execute('shapeNextBurn',env)
    assert result==Lex(node=useful,label='set-ap') and removed==[tiny]
    assert env['_shapeMinimumSkipped'] and not events
    errs['AP']=0
    assert execute('shapeNextBurn',env)==0 # Only an unexecutable plane trim remains.
    assert errs['PLANE']>env['SHAPE_ANG_TOL']
    print('PASS: skipping a tiny plane correction falls through to a useful apsis burn, then reports no executable correction while preserving the strict plane target')


def check_apsis_fallback_requires_geometric_need():
    env,removed,events=fixture();calls=[]
    errs=Lex(AP=1740,PE=0,AOP=0)
    env['SHIP'].APOAPSIS=399012
    env.update(targets=Lex(AP=397272,PE=9300,AOP=90),shapeErrors=lambda _:errs)
    def apsis(*args):calls.append(args[3]);return Skip('skip')
    env['_apsisBurn']=apsis
    assert execute('shapeNextBurn',env)==0 and calls==['set-ap']
    # The fallback still exists when the requested Ap really is below the
    # current Pe and a direct burn at Pe cannot achieve it.
    calls.clear();env['SHIP'].PERIAPSIS=410000;env['SHIP'].APOAPSIS=450000
    env['targets']=Lex(AP=397272)
    errs.clear();errs['AP']=450000-397272
    assert execute('shapeNextBurn',env)==0 and calls==['set-pe-for-ap']
    assert not removed and not events
    print('PASS: reported set-pe-for-ap fallback cannot run after a skipped tiny ordinary AP trim; it remains available when target Ap truly lies below current Pe')


def check_phase_holds_without_false_completion():
    env,removed,events=fixture();tiny=NS(DELTAV=NS(MAG=.1),ETA=14400)
    saved=dict(phase='SHAPE',shape_budget_spent=25,mission_id='minmus_kolniya_flats_return')
    def forbidden(*_):raise AssertionError('tiny correction reached execution/budget/advance')
    def plan(_):
        env['_shapeNodeAboveMinimum'](tiny,'plane');return 0
    env.update(phaseLabel='SHAPE',prefix='SHAPE_',MAX_SHAPE_BURNS=12,MAX_RETRIES=5,
        stateGet=saved.get,shapeTargetsWithPrefix=lambda _:Lex(INC=63.4),
        shapeErrors=lambda _:Lex(PLANE=.2),shapeConverged=lambda _:False,
        shapeNextBurn=plan,_targetSummary=lambda _:'',_errorSummary=lambda _:'',
        executeManeuver=forbidden,_shapeReserveBurn=forbidden,nextPhase=forbidden,
        orbitSummary=lambda:None,yieldToPrompt=lambda:events.append(('hold',)))
    execute('_runShapePhase',env)
    assert removed==[tiny] and events==[('hold',)]
    assert saved==dict(phase='SHAPE',shape_budget_spent=25,mission_id='minmus_kolniya_flats_return')
    run=function_body(SOURCE,'_runShapePhase')
    assert run.index('_shapeNodeAboveMinimum(NEXTNODE,planned["label"])')<run.index('_shapeReserveBurn(NEXTNODE)')<run.index('executeManeuver()')
    assert 'SET planned TO replanned.' in run
    assert 'Sub-minimum corrections were skipped; requested orbit tolerances still apply.' in run
    print('PASS: remaining0.2deg error with only a0.1m/s trim holds SHAPE at the prompt, spends no budget and cannot silently advance to science/landing; retry execution shares final minimum admission')


def check_retry_shrink_cannot_execute():
    env,removed,events=fixture()
    initial=NS(DELTAV=NS(MAG=1),ETA=14400)
    tiny=NS(DELTAV=NS(MAG=.1),ETA=14400)
    queued=[Lex(node=initial,label='plane'),Lex(node=tiny,label='aop')]
    def plan(_):
        result=queued.pop(0)
        env['HASNODE']=True;env['NEXTNODE']=result['node'];return result
    env.update(phaseLabel='SHAPE',prefix='SHAPE_',MAX_SHAPE_BURNS=12,MAX_RETRIES=5,
        shapeTargetsWithPrefix=lambda _:Lex(INC=63.4),shapeErrors=lambda _:Lex(PLANE=.2),
        shapeConverged=lambda _:False,shapeNextBurn=plan,
        _targetSummary=lambda _:'',_errorSummary=lambda _:'',
        _shapeReserveBurn=lambda nd:events.append(('budget',nd)) or True,
        executeManeuver=lambda:events.append(('execute',env['NEXTNODE'])) or False,
        yieldToPrompt=lambda:events.append(('hold',)))
    execute('_runShapePhase',env)
    assert events==[('budget',initial),('execute',initial),('wait',10),('wait',.1),('hold',)]
    assert removed==[initial,tiny] and env['_shapeMinimumSkipped']
    assert env['planned']['label']=='aop' # Replans update objective diagnostics.
    print('PASS: a retry that produces a0.1m/s node is rejected at the common execution boundary before any second budget charge or burn, and retains its correct replanned label')


if __name__=='__main__':
    check_all_final_nodes()
    check_refinement_cannot_bypass()
    check_tiny_plane_allows_useful_apsis()
    check_apsis_fallback_requires_geometric_need()
    check_phase_holds_without_false_completion()
    check_retry_shrink_cannot_execute()
