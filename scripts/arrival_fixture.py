"""Shared source-function wiring for arrival fixtures; no KSP simulation."""
import re
from types import SimpleNamespace as NS
import check_landing_guidance as ks

POLICY=(ks.ROOT/'lib/arrival_policy.ks').read_text()
CONIC=(ks.ROOT/'lib/conic_time.ks').read_text()
MANEUVER=(ks.ROOT/'lib/maneuver.ks').read_text()
ks.SOURCES+='\n'+POLICY+'\n'+CONIC


class EventEta:
    def __init__(self,clock,epoch):self.clock,self.epoch=clock,epoch
    PERIAPSIS=property(lambda self:self.epoch-self.clock.SECONDS)


def install(env):
    for name,value in re.findall(r'GLOBAL (\w+) IS ("[^"\n]*"|-?\d+(?:\.\d+)?)\.',POLICY+'\n'+MANEUVER):
        env.setdefault(name,value[1:-1] if value.startswith('"') else float(value))
    for name in re.findall(r'GLOBAL FUNCTION (\w+)',POLICY+'\n'+CONIC):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)


def torch_hardware(env):
    env['SHIP'].MASS=1.287
    env['SHIP'].ENGINES=[NS(IGNITION=True,FLAMEOUT=False,AVAILABLETHRUST=55,
                           THROTTLELOCK=False,THRUSTLIMIT=100)]
    env['STAGE']=NS(DELTAV=NS(VACUUM=1000))
