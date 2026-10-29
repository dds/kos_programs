"""Reported638m powered residual, tight budget and native-response hazards.

Source control-flow tests with synthetic footprints, not a KSP flight replay.
"""
import math
from types import SimpleNamespace as NS

import check_deorbit_solver as solver
from check_landing_range import powered_source
from check_runtime_contracts import run


def context(fault='none',legacy=False):
    aim,initial,retro0=51903.,51265.,24.
    def oracle(ut,retro,normal):
        delta=retro-retro0
        down=initial-6678.85*delta+1200*delta*delta
        cross=0 if fault!='cross' else 700
        result=solver.impact(ut,retro,normal,down-15000,cross)
        if fault=='no-impact' and delta:result['HAS_IMPACT']=False
        if fault=='flat':result['DOWNFIELD']=initial
        if fault=='nan' and delta:result['DOWNFIELD']=math.nan
        return result
    env,count,trials=solver.environment(oracle)
    count.value=60;nodes=[];models=[]
    evaluate=env['_evalGeometricDeorbitNode']
    def measured(ut,retro,lat,lng,lead,goal,normal=0):
        row=evaluate(ut,retro,lat,lng,lead,goal,normal)
        if row['VALID']:row['ERR']=row['DOWNFIELD']-goal
        return row
    def plan(ut,retro,normal):
        node=NS(TIME=ut,retro=retro,normal=normal);nodes.append(node);return node
    def read(node,lat,lng,goal):
        row=oracle(node.TIME,node.retro,node.normal);row['ERR']=row['DOWNFIELD']-goal
        return row
    def policy(node,*args):
        models.append(node.retro)
        goal=aim+(4000 if fault=='moving-model' and len(models)>1 else 0)
        return solver.Lex(VALID=True,AIM=goal,MIN=goal-500,MAX=goal+500,DIAGNOSTIC='fixture')
    env.update(LANDING_POWERED_LEAD=1,solved=oracle(1000,retro0,0),geometry=dict(UT=1000),
        targetLat=-10.590,targetLng=99.490,minLead=120,minRetroDv=2,maxRetroDv=120,
        desiredDownfield=15000,minDownfield=10000,maxDownfield=20000,
        _evalGeometricDeorbitNode=measured,_planRetroNode=plan,_readGeometricDeorbitNode=read,
        landingDeorbitLeadPolicy=policy,remove_probe=lambda node:nodes.remove(node),
        charge_forecast=lambda:setattr(count,'value',count.value+1))
    if fault=='abort':env['ABORT']=True
    if legacy:env['_targetDeorbitLocalAlongTrack']=lambda *args:False
    source=powered_source().replace('SET _deorbitEvaluations TO _deorbitEvaluations+1.','charge_forecast().')
    result=run(source,env)
    return env,count,trials,models,nodes,result


def check_reported_residual():
    old,*_=context(legacy=True)
    assert not old['poweredAccepted']
    env,count,trials,models,nodes,result=context()
    assert env['poweredAccepted'] and result is None and not nodes
    assert count.value==64 and len(trials)==2 and len(models)==2
    assert abs(env['solved']['ERR'])<60 and env['solved']['CROSS']==0
    assert env['solved']['UT']==1000 and env['solved']['NORMAL']==0
    assert 0<24-env['solved']['RETRO']<.11
    assert env['minDownfield']==51403 and env['maxDownfield']==52403
    assert env['targetLat']==-10.590 and env['targetLng']==99.490
    assert env['stepAim']['MODE']=='local'
    print('PASS: actual powered loop polishes reported51265/51903m residual under unchanged500m tolerance using one0.25m/s probe, a~0.1m/s correction and fresh forecast at64/64; old four-trial gate holds; no epoch/normal/target change')


def check_bad_polish_stays_unflown():
    for fault in ('cross','flat','nan','no-impact','moving-model','abort'):
        env,count,trials,models,nodes,result=context(fault)
        assert not env['poweredAccepted'] and result is False and not nodes,fault
        assert count.value<=64,fault
        if fault=='moving-model':assert len(models)==2
    env,count,_=solver.environment(lambda *args:None)
    env['LANDING_POWERED_LEAD']=1
    row=solver.impact(1000,24,0,51265-15000,0);row['ERR']=-638
    assert env['_targetDeorbitLocalAlongTrack'](row,51403,52403)
    count.value=63
    result=env['_targetDeorbitPolishAlongTrack'](row,-10.590,99.490,120,51903,51403,52403,2,120,63)
    assert result is row and count.value==63
    print('PASS: cross-track/flat/NaN/missing-impact/changed-powered-model/Abort and insufficient-budget cases never accept or create an unchecked final burn; fresh powered validation remains mandatory')


if __name__=='__main__':
    check_reported_residual()
    check_bad_polish_stays_unflown()
