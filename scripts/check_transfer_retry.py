"""Execute operator retry state changes against fixture state, not kOS/KSP."""
from types import SimpleNamespace as NS
import check_landing_guidance as ks

SOURCE = (ks.ROOT/'cmd/transferretry.ks').read_text()
ks.SOURCES += '\n'+SOURCE


class KNumber(float):
    # KerboScript string concatenation coerces numeric operands.
    def __radd__(self, other):
        return other+str(float(self)) if isinstance(other,str) else other+float(self)


def fixture():
    state = dict(phase='XING', mission_id='mun_economy_return', target='Mun',
                 burn_started='true', burn_pending='true', burn_phase='XING',
                 burn_departure_target='Mun', burn_departure_time=900,
                 burn_status='waiting-for-thrust', burn_abort_reason='stage-recovery-failed',
                 xing_arrival_ut=2000, xing_arrival_target='Mun',
                 last_burn_report='previous cutoff', launch_window=50)
    ship = NS(BODY=NS(NAME='Kerbin', ATM=NS(HEIGHT=70000)),
              ORBIT=NS(ECCENTRICITY=.001, HASNEXTPATCH=False),
              PERIAPSIS=78000, APOAPSIS=79000, THRUST=0,
              CONTROL=NS(PILOTMAINTHROTTLE=0))
    def remove_prefix(prefix):
        for key in list(state):
            if key.startswith(prefix): del state[key]
    env = dict(SHIP=ship, HASNODE=False, ABORT=False, TIME=NS(SECONDS=KNumber(1000)),
               ROUND=lambda *args: KNumber(round(*args)), stateGet=state.get,
               stateSet=lambda key,value: state.update({key:value}),
               stateRemove=lambda key: state.pop(key,None),
               stateRemovePrefix=remove_prefix)
    return env,state


def main():
    env,state=fixture()
    assert ks.call('_transferRetry',env)
    assert not any(key.startswith('burn_') for key in state)
    assert 'xing_arrival_ut' not in state and 'xing_arrival_target' not in state
    for key,value in dict(phase='XING',mission_id='mun_economy_return',target='Mun',
                          last_burn_report='previous cutoff',launch_window=50).items():
        assert state[key]==value
    assert state['reload_required']=='false'
    for change in (
        lambda env,state: state.update(phase='BPLANE'),
        lambda env,state: env.update(HASNODE=True),
        lambda env,state: env.update(ABORT=True),
        lambda env,state: setattr(env['SHIP'],'THRUST',1),
        lambda env,state: setattr(env['SHIP'].CONTROL,'PILOTMAINTHROTTLE',1),
        lambda env,state: setattr(env['SHIP'].BODY,'NAME','Mun'),
        lambda env,state: setattr(env['SHIP'].ORBIT,'ECCENTRICITY',1.1),
        lambda env,state: setattr(env['SHIP'].ORBIT,'HASNEXTPATCH',True),
        lambda env,state: setattr(env['SHIP'],'PERIAPSIS',69000),
        lambda env,state: setattr(env['SHIP'],'APOAPSIS',2200000),
    ):
        env,state=fixture()
        change(env,state)
        before=dict(state)
        assert not ks.call('_transferRetry',env)
        assert state==before
    assert SOURCE.index('bootPreamble().')<SOURCE.index('stateGet(')
    assert 'missionOverrideClear' not in SOURCE and 'executeManeuver' not in SOURCE
    print('PASS: no-thrust retry clears departure hold; preserves mission; ten rejection cases leave state untouched')


if __name__=='__main__':
    main()
