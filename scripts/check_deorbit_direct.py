"""Stalled ballistic response versus measured powered response.

Runs the real outer planner, fallback and shared pre-burn refitter. The
response curve is synthetic, anchored at boot018's reported state; no
claim that it reconstructs native TR/terrain or the actual derivative.
"""
from types import SimpleNamespace as NS

import check_deorbit_solver as solver
from check_codebase import function_body
from check_landing_range import powered_source
from check_runtime_contracts import run


class Flag:
    def __init__(self,value=False):self.value=value
    def __bool__(self):return self.value


def context(case='ok',used=43,legacy=False):
    retro0,normal0=18.9307594727723,-.872702194955142
    ut=170. if case=='late' else 5039859.86456794
    def oracle(ut,retro,normal):
        # A frozen-goal Newton step has no useful response. Ignition and
        # powered travel may still respond to retro dV independently.
        return solver.impact(ut,retro,normal,29529-15000,227)
    env,count,trials=solver.environment(oracle)
    count.value=used
    measured=env['_evalGeometricDeorbitNode']
    def evaluate(ut,retro,lat,lng,lead,aim,normal=0):
        row=measured(ut,retro,lat,lng,lead,aim,normal)
        if row['VALID']:row['ERR']=row['DOWNFIELD']-aim
        return row
    nodes,models,checks=[],[],solver.Lex(VALID=False)
    present,abort=Flag(),Flag()
    home=NS(NAME='Mun')
    env.update(LANDING_POWERED_LEAD=1,HASNODE=present,ABORT=abort,
               _deorbitLastCheck=checks,
               SHIP=NS(BODY=home,STATUS='ORBITING',PERIAPSIS=14000.,THRUST=0.,
                       CONTROL=NS(MAINTHROTTLE=0.,PILOTMAINTHROTTLE=0.),DELTAV=NS(VACUUM=1000)),
               stateGet=lambda key,default='':('true' if case=='committed' and key=='deorbit_burn_started' else default),
               solved=oracle(ut,retro0,normal0),geometry=dict(UT=ut),
               targetLat=-10.590,targetLng=99.490,minLead=120,minRetroDv=2,maxRetroDv=120,
               desiredDownfield=15000,minDownfield=10000,maxDownfield=20000,
               _evalGeometricDeorbitNode=evaluate,
               _targetDeorbitTerrainAccepted=lambda *args:case!='terrain',
               landingLightNodeAllowed=lambda *args:case!='light')
    if case=='thrust':env['SHIP'].THRUST=.1
    if case=='main':env['SHIP'].CONTROL.MAINTHROTTLE=.1
    if case=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
    if case=='suborbital':env['SHIP'].STATUS='SUB_ORBITAL'
    def plan(ut,retro,normal):
        node=NS(TIME=ut,ETA=ut-env['TIME'].SECONDS,PROGRADE=-retro,NORMAL=normal,
                RADIALOUT=0,DELTAV=NS(MAG=(retro**2+normal**2)**.5))
        nodes.append(node);present.value=True;return node
    def remove(node):
        nodes.remove(node);present.value=bool(nodes)
    def policy(node,*args):
        retro=-node.PROGRADE
        error=-18841-(12000 if case!='reverse' else -12000)*(retro-retro0)
        if case=='flat':error=-18841
        if case=='nan' and len(models)>=2:error=float('nan')
        models.append((retro,error))
        env['TIME'].SECONDS+=21 if case=='late' and len(models)==4 else 10
        if len(models)==3 and case=='abort':abort.value=True
        if len(models)==3 and case=='body':env['SHIP'].BODY=NS(NAME='Kerbin')
        return solver.Lex(VALID=case!='invalid' or len(models)<3,REASON='bad-model',
                          AIM=29529-error,MIN=29529-error-500,MAX=29529-error+500,DIAGNOSTIC='fresh fixture')
    def read(node,lat,lng,aim):
        row=oracle(node.TIME,-node.PROGRADE,node.NORMAL)
        row['ERR']=row['DOWNFIELD']-aim
        if len(models)>=3:
            if case=='cross':row['CROSS']=900
            if case=='fuel':row['DV']=2000
            if case=='normal':row['NORMAL']=11
        return row
    admission=function_body(solver.SOURCE,'landingDeorbitNodeAccepted')
    ready=function_body(solver.SOURCE,'landingDeorbitNodeReady')
    fallback=function_body(solver.SOURCE,'_targetDeorbitPoweredFallback').replace('REMOVE nd.','remove_probe(nd).')
    def admit(node,lat,lng,emit=True):
        assert emit is False # Compact intermediate rows; retain final model once.
        scope=dict(env,nd=node,targetLat=lat,targetLng=lng,emitModelDiagnostic=emit)
        result=run(admission,scope)
        checks.clear();checks.update(scope['_deorbitLastCheck'])
        return result
    def fit(row,lat,lng,lead):
        if case=='foreign':nodes.append('foreign');present.value=True
        return run(fallback,dict(env,solved=row,targetLat=lat,targetLng=lng,minLead=lead))
    env.update(_planRetroNode=plan,remove_probe=remove,landingDeorbitLeadPolicy=policy,
               _readGeometricDeorbitNode=read,landingDeorbitNodeAccepted=admit,
               landingDeorbitNodeReady=lambda node,lat,lng,emit=True:run(ready,dict(env,nd=node,targetLat=lat,targetLng=lng,emitModelDiagnostic=emit)),
               _targetDeorbitPoweredFallback=fit,
               charge_forecast=lambda:setattr(count,'value',count.value+1),
               reserve_fit=lambda:setattr(count,'value',count.value+7))
    source=powered_source().replace('SET _deorbitEvaluations TO _deorbitEvaluations+1.','charge_forecast().')
    source=source.replace('SET _deorbitEvaluations TO _deorbitEvaluations+7.','reserve_fit().')
    if legacy:
        source=source[:source.index('    // Frozen ballistic goals')]+source[source.index('    IF ABORT OR NOT poweredAccepted {'):]
    result=run(source,env)
    return env,count,trials,models,nodes,result,checks


def check_reported_stall():
    old,count,_,models,nodes,result,_=context(legacy=True)
    assert result is False and not old['poweredAccepted'] and count.value==48 and len(models)==1 and not nodes
    for case in ('ok','reverse'):
        env,count,trials,models,nodes,result,last=context(case)
        assert result is None and env['poweredAccepted'] and not nodes
        assert count.value==55 and len(trials)==4 and len(models)==4
        assert abs(env['solved']['ERR'])<1 and env['solved']['CROSS']==227
        assert env['solved']['UT']==5039859.86456794 and env['solved']['NORMAL']==-.872702194955142
        assert env['desiredDownfield']==last['POLICY']['AIM']
        assert env['minDownfield']==last['POLICY']['MIN'] and env['maxDownfield']==last['POLICY']['MAX']
        assert len(models)-1<=7 and 2<=env['solved']['RETRO']<=120
    print('PASS: actual frozen-goal planner holds at48/64 on a synthetic flat-ballistic response anchored at the native18.8km miss; shared direct-powered refitter solves both derivative signs at55/64, preserving epoch/normal/500m corridor and fresh policy/terrain/light checks')


def check_limits_and_failures():
    for case in ('flat','nan','cross','fuel','normal','terrain','light','invalid','abort','body',
                 'late','committed','thrust','main','pilot','suborbital','foreign'):
        env,count,_,models,nodes,result,_=context(case)
        assert result is False and not env['poweredAccepted'],case
        assert count.value<=64 and len(models)-1<=7,case
        assert nodes==(['foreign'] if case=='foreign' else []),(case,nodes)
        if case in ('flat','nan','cross','fuel','normal','terrain','light','invalid'):
            assert len(models)>1,case
        if case in ('committed','thrust','main','pilot','suborbital','foreign'):
            assert len(models)==1,case
    exact,count,_,_,nodes,result,_=context(used=56)
    assert exact['poweredAccepted'] and count.value==64 and not nodes and result is None
    short,count,_,models,nodes,result,_=context(used=57)
    assert not short['poweredAccepted'] and count.value==62 and len(models)==1 and not nodes and result is False
    print('PASS: full seven-forecast reservation is required even at the64 limit; invalid/flat/NaN response, terrain/light/cross/normal/fuel, Abort/body/deadline, interrupted/throttled/descent craft and foreign nodes remain unapproved; all owned temporary nodes removed')


if __name__=='__main__':
    check_reported_stall()
    check_limits_and_failures()
