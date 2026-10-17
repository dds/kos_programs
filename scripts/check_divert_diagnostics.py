"""Archive diagnostic sampling/budget guards; no kOS or game execution."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask

SOURCE=(ROOT/'cmd/divertcheck.ks').read_text()
ks.SOURCES+='\n'+SOURCE


def check_point_metrics():
    radius=60000
    scale=radius*math.pi/180
    requests=[]
    def geo(lat,lng):
        requests.append((lat,lng))
        return NS(TERRAINHEIGHT=3000+.1*lat*scale+.2*lng*scale)
    env=ks.environment()
    env.update(SHIP=NS(BODY=NS(RADIUS=radius)),LATLNG=geo,centerLat=0,centerLng=0,
               altDatum=4352,lateralAcc=.075,hs=0,
               geoDistance=lambda a,b,c,d:math.hypot(a-c,b-d)*scale)
    for north,east in ((0,0),(50,-50),(-200,200)):
        requests.clear()
        point=ks.call('_divertCheckPoint',env,north,east)
        assert point['VALID'] and len(requests)==9
        assert abs(point['ELEVATION']-(3000+.1*north+.2*east))<1e-8
        expected=math.hypot(.1,.2/math.cos(math.radians(point['LAT'])))
        assert abs(point['GRADE']-expected)<1e-10
        assert point['GRADE']==point['INDEPENDENT']
        assert abs(point['CLEARANCE']-(4352-point['ELEVATION']))<1e-8
        assert abs(point['DIST']-math.hypot(north,east))<1e-8
        assert abs(point['TRANSIT']-2*math.sqrt(point['DIST']/.075))<1e-8
    print('PASS: archive probe reports raw neighbor heights, independent/production grade, surface distance, altitude clearance and the exact correction-time estimate')


def check_capture_bounds():
    main=function_body(SOURCE,'_cmdDivertcheck')
    loop=main[main.index('LOCAL index IS 0.'):main.index('SET CONFIG:IPU TO priorIpu.')]
    def without_reports(nodes):
        return [(s,without_reports(yes),without_reports(no)) for s,yes,no in nodes if not s.startswith('report(')]
    nodes=without_reports(ks.parse(loop))
    for scenario,expected in (('complete',81),('count',9),('deadline',3),('abort',1),('link',1)):
        env=ks.environment()
        points=[]
        def wait(_):
            if scenario=='deadline':env['TIME'].SECONDS+=2
            if scenario=='abort':env['ABORT']=True
            if scenario=='link':env['capture']['COMPLETE']=False
        env.update(count=9 if scenario=='count' else 81,stepM=50,began=0,
                   capture=dict(COMPLETE=True),fixture_wait=wait,
                   _divertCheckPoint=lambda n,e:points.append((n,e)) or dict(VALID=True))
        ks.run(nodes,env)
        assert len(points)==expected and env['recorded']==expected
        assert points[0]==(0,0) and len(points)==len(set(points))
        if scenario=='complete':
            assert set(points)=={(n*50,e*50) for n in range(-4,5) for e in range(-4,5)}
    print('PASS: center-first diagnostic visits unique points and stops at 81/count limit, six game seconds, ABORT or archive loss')


def check_diagnostic_control_and_cpu():
    clean=mask(SOURCE)
    assert not re.search(r'(?<!:)\b(?:LOCK|UNLOCK|STAGE|ADD|REMOVE|REBOOT|SHUTDOWN)\b(?!:)',clean)
    assert not re.search(r'\b(?:missionOverrideUpdate|missionOverrideClear|nextPhase|landExecute)\s*\(',clean)
    assert re.findall(r'stateSet\("([^"]+)"',SOURCE)==['landing_prior_ipu']
    assert re.findall(r'stateRemove\("([^"]+)"',SOURCE)==['landing_prior_ipu']
    main=function_body(SOURCE,'_cmdDivertcheck')
    setup=main[main.index('LOCAL priorIpu'):main.index('report("STATS divert-check schema')]
    cleanup=main[main.index('SET CONFIG:IPU TO priorIpu.'):main.index('report("STATS divert-check sampled')]
    for prior in (150,2000,2500):
        saved={}
        env=ks.environment()
        env.update(CONFIG=NS(IPU=prior),stateSet=lambda key,value:saved.update({key:value}),
                   stateRemove=lambda key:saved.pop(key,None))
        ks.run(ks.parse(setup),env)
        assert env['CONFIG'].IPU==max(prior,2000)
        ks.run(ks.parse(cleanup),env)
        assert env['CONFIG'].IPU==prior and not saved
    assert 'diagnosticArchiveOpen("divertcheck")' in SOURCE
    assert 'diagnosticArchiveClose(capture' in SOURCE
    assert 'COPYPATH(flightLogPath(), sidecar)' in SOURCE
    print('PASS: diagnostics never actuate or change mission/return intent; scoped CPU restores; report and copied flight log go directly through the archive writer')


if __name__=='__main__':
    check_point_metrics()
    check_capture_bounds()
    check_diagnostic_control_and_cpu()
