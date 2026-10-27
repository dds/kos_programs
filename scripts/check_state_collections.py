"""Caller persistence using actual stateGet/stateSet source and JSON reboots.

Only disk I/O is substituted. Control flow, cache aliases and unchanged-value
suppression execute the repository's KerboScript; this is not the native VM.
"""
import json
import re

import check_landing_guidance as ks
import check_hop_route as hop
import check_landing_light_wait as light
import check_midcourse as mid
from check_codebase import ROOT, function_body
from check_runtime_contracts import KList

STATE=(ROOT/'lib/state.ks').read_text()
ks.SOURCES=STATE+'\n'+ks.SOURCES


class Lex(dict):
    LENGTH=property(len)
    KEYS=property(lambda self:list(self))
    TYPENAME='Lexicon'
    COPY=property(lambda self:Lex(self))
    HASKEY=dict.__contains__
    ADD=dict.__setitem__
    REMOVE=dict.__delitem__
    def __radd__(self,left):return left+repr(self)


class Items(KList):
    TYPENAME='List'
    def __radd__(self,left):return left+repr(self)


def collection(value):
    if isinstance(value,dict):return Lex((key,collection(item)) for key,item in value.items())
    if isinstance(value,list):return Items(collection(item) for item in value)
    return value


class Store:
    def __init__(self,initial):
        self.disk=json.dumps(initial)
        self.writes=[]
        self.reboot()
    def reboot(self):
        self.cache=collection(json.loads(self.disk))
        self.env=dict(_cache=self.cache,_ensureLoaded=lambda:None,_flush=self.flush)
    def flush(self):
        self.disk=json.dumps(self.cache)
        self.writes.append(self.disk)
    def get(self,key,default=''):return ks.call('stateGet',self.env,key,default)
    def set(self,key,value):return ks.call('stateSet',self.env,key,value)
    def remove(self,key):return ks.call('stateRemove',self.env,key)
    def bind(self,env):
        env.update(stateGet=self.get,stateGetNum=self.get,stateSet=self.set,stateRemove=self.remove)
    def saved(self):return json.loads(self.disk)


class PowerLoss(Exception):pass


def execute(source,env):
    source=re.sub(r'\bPRINT\s+(?:"[^"]*"|[^.\"])*\.', '',source)
    try:ks.run(ks.parse(source),env)
    except ks.Returned as result:return result.value


def check_real_cache_contract():
    store=Store(dict(record=dict(waiting=True,alarm='old'),budget=36.3))
    aliased=store.get('record')
    aliased['waiting']=False
    assert not store.set('record',aliased) and not store.writes
    store.reboot();assert store.get('record')['waiting']
    edited=store.get('record').COPY;edited['waiting']=False
    assert store.set('record',edited) and len(store.writes)==1
    store.reboot();assert not store.get('record')['waiting'] and store.get('budget')==36.3
    print('PASS: actual stateGet/stateSet source reproduces lost in-place edits after JSON reboot; copied edits force one durable write and preserve unrelated budget')


def check_final_checkpoint_is_consumed():
    for kac in (True,False):
        for copy_first in (False,True):
            env,initial,events,alarms,moon,_=mid.retry_environment()
            initial['bplane_retry_wait']=dict(mission=initial['mission_id'],launch=initial.get('launch_time',0),
                phase=initial['phase'],target=moon.NAME,wakeUt=2000,alarm='old',waiting=True)
            initial['bplane_budget_spent']=36.3
            store=Store(initial);store.bind(env);env['ADDONS'].KAC.AVAILABLE=kac
            source=function_body(mid.ARRIVAL,'bplaneClearRetryWait')
            if not copy_first:source=source.replace('SET pending TO pending:COPY.','')
            env['keepCheckpoint']=True
            execute(source,env)
            assert len(store.writes)==int(copy_first)
            store.reboot();store.bind(env)
            record=store.get('bplane_retry_wait')
            assert record['waiting'] is (not copy_first)
            assert record['alarm']==('' if copy_first else 'old')
            assert record['wakeUt']==2000 and store.get('bplane_budget_spent')==36.3
            assert bool(ks.call('_bplaneRetryWaitPending',env,moon)) is (not copy_first)
            assert ks.call('_bplaneRetryWaitPending',env,moon,False)
    print('PASS: consuming the final B-plane checkpoint survives an immediate reboot with/without KAC; removing the caller copy reproduces an extra waiting checkpoint without any budget change')


def check_alarm_is_durable_before_solar():
    for copy_first in (False,True):
        env,initial,events,alarms=light.fixture()
        context=env['_landingLightWaitContext']()
        initial['landing_light_wait']=dict(context=context,wakeUt=2000,estimateUt=2400,
            forecastFound=True,alarm='old')
        initial['shape_budget_spent']=49
        store=Store(initial);store.bind(env)
        def interrupted(*args):raise PowerLoss()
        env['enterSolarCoast']=interrupted
        source=function_body(light.SOURCE,'landingAwaitLitGroundTrack')
        if not copy_first:source=source.replace('SET saved TO saved:COPY.','')
        try:execute(source,env)
        except PowerLoss:pass
        else:raise AssertionError('solar interruption not reached')
        assert len(store.writes)==int(copy_first)
        store.reboot()
        alarm=store.get('landing_light_wait')['alarm']
        assert (alarm!='old') is copy_first
        assert store.get('landing_light_wait')['context']==context
        assert store.get('shape_budget_spent')==49 and alarms
        if copy_first:assert alarm in alarms
    print('PASS: replacement landing-light alarm is durably recorded before solar work can lose power; removing the copy leaves stale disk metadata even though a new KAC alarm exists')


def check_waypoint_is_durable_before_handoff():
    for append in (False,True):
        for copy_first in (False,True):
            env,initial,updates,events,_=hop.fixture()
            initial['hop_route_index']=int(append)
            store=Store(initial);store.bind(env)
            env['selectedWaypoint']=lambda:hop.NS(LATITUDE=1,LONGITUDE=3)
            def interrupted(*args):raise PowerLoss()
            env['_hopScheduleSite']=interrupted
            source=function_body(hop.HOP,'hopWaypoint')
            if not copy_first:source=source.replace('stateGet("hop_route_sites",LIST()):COPY','stateGet("hop_route_sites",LIST())')
            try:execute(source,env)
            except PowerLoss:pass
            else:raise AssertionError('route interruption not reached')
            assert len(store.writes)==int(copy_first)
            store.reboot()
            expected=[[0,1],[0,2]]
            if copy_first:
                if append:expected.append([1,3])
                else:expected[1]=[1,3]
            assert store.get('hop_route_sites')==expected
            assert store.get('hop_route_index')==int(append) and not updates
            assert store.get('phase')=='HOP_REVIEW' and store.get('hop_route_active')
            assert store.get('hop_route_restore')['RETURN_PE']==53000
    print('PASS: both replacement and appended waypoint survive power loss before overrides/pending-leg writes; a removed copy reproduces the lost route, while completion index, mission review and original return settings remain unchanged')


if __name__=='__main__':
    check_real_cache_contract()
    check_final_checkpoint_is_consumed()
    check_alarm_is_durable_before_solar()
    check_waypoint_is_durable_before_handoff()
