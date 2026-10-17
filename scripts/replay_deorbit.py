"""Independent two-body replay of a deorbitcheck snapshot; never flight approval.

Usage: python3 scripts/replay_deorbit.py /path/to/deorbitcheck.log
Bound, same-body, prograde/retrograde-only nodes. No thrust, terrain mesh,
powered descent, finite burn, staging or attitude simulation. Snapshot rows
are not atomic, so metre-scale propagation residuals are expected.
"""
import json
import math
from pathlib import Path
import re
import sys

import numpy as np


def parse_snapshot(text):
    rows = {}
    for line in text.splitlines():
        if not line.startswith('STATS deorbit-check '): continue
        values = dict(re.findall(r'(\w+)=(V\([^)]*\)|[^\s]+)', line))
        label = line.removeprefix('STATS deorbit-check ').split()[0].split('=')[0]
        rows.setdefault(label, []).append(values)
    def first(label): return rows[label][0]
    sample = next(row for row in rows['sample'] if 'impactUT' in row)
    light = rows.get('light', [])
    target_now = next((row for row in light if row.get('point')=='target-now'), {})
    now = float(target_now.get('ut',first('schema')['ut']))
    target = first('target')
    if target.get('found','true').casefold() == 'false':
        raise ValueError('Snapshot has no resolved landing target')
    # The terrain row is a separate entry without the target's FOUND fields.
    terrain = next(row for row in rows['target'] if 'terrain' in row)
    def vector(value): return np.array([float(x) for x in value[2:-1].split(',')])
    body, current, node = first('body'), first('current'), first('node')
    if sample.get('nativeBody',body.get('name')) != body.get('name'):
        raise ValueError('Replay requires a same-body impact')
    return dict(now=now,mu=float(body['mu']),radius=float(body['radius']),
                spin=vector(body['angularVel']),position=vector(current['relativePos']),
                velocity=vector(current['orbitalVel']),current_lat=float(current['lat']),
                current_lng=float(current['lng']),target_lat=float(target_now.get('lat',target['configuredLat'])),
                target_lng=float(target_now.get('lng',target['configuredLng'])),target_terrain=float(terrain['terrain']),
                burn_ut=float(node['ut']),prograde=float(node['prograde']),
                normal=float(node['normal']),radial=float(node['radial']),
                node_pe=float(node['pe']),impact_ut=float(sample['impactUT']),
                impact_lat=float(sample['impactLat']),impact_lng=float(sample['impactLng']))


def ellipse(position, velocity, mu):
    radius = np.linalg.norm(position)
    momentum = np.cross(position,velocity)
    eccentric = np.cross(velocity,momentum)/mu-position/radius
    ecc = np.linalg.norm(eccentric)
    inverse_semi = 2/radius-np.dot(velocity,velocity)/mu
    if inverse_semi <= 0 or ecc >= 1 or np.linalg.norm(momentum) < 1e-9:
        raise ValueError('Replay requires a nonradial bound ellipse')
    semi = 1/inverse_semi
    peri = eccentric/ecc if ecc > 1e-10 else position/radius
    normal = momentum/np.linalg.norm(momentum)
    transverse = np.cross(normal,peri)
    nu = math.atan2(np.dot(position,transverse),np.dot(position,peri))
    anomaly = math.atan2(math.sqrt(1-ecc*ecc)*math.sin(nu),ecc+math.cos(nu))
    mean0, rate = anomaly-ecc*math.sin(anomaly), math.sqrt(mu/semi**3)
    def state(dt):
        mean = (mean0+rate*dt+math.pi)%(2*math.pi)-math.pi
        anomaly = mean
        for _ in range(20):
            step = (anomaly-ecc*math.sin(anomaly)-mean)/(1-ecc*math.cos(anomaly))
            anomaly -= step
            if abs(step) < 1e-13: break
        cosine, sine = math.cos(anomaly),math.sin(anomaly)
        point = semi*((cosine-ecc)*peri+math.sqrt(1-ecc*ecc)*sine*transverse)
        speed = math.sqrt(mu*semi)/np.linalg.norm(point)*(-sine*peri+math.sqrt(1-ecc*ecc)*cosine*transverse)
        return point,speed
    return state,semi*(1-ecc),normal


def rotate(vec, spin, elapsed):
    rate = np.linalg.norm(spin)
    if rate < 1e-12: return vec.copy()
    axis, angle = spin/rate, rate*elapsed
    return (vec*math.cos(angle)+np.cross(axis,vec)*math.sin(angle)
            +axis*np.dot(axis,vec)*(1-math.cos(angle)))


def angle(first, second):
    # atan2 preserves small misses better than acos near one.
    return math.atan2(np.linalg.norm(np.cross(first,second)),np.dot(first,second))


def replay(data):
    if abs(data['normal']) > 1e-6 or abs(data['radial']) > 1e-6:
        raise ValueError('Replay supports prograde/retrograde-only nodes')
    before,pre_peri,plane = ellipse(data['position'],data['velocity'],data['mu'])
    burn_pos,burn_vel = before(data['burn_ut']-data['now'])
    after,post_peri,_ = ellipse(burn_pos,burn_vel+data['prograde']*burn_vel/np.linalg.norm(burn_vel),data['mu'])
    impact_pos,_ = after(data['impact_ut']-data['burn_ut'])
    spin = data['spin']
    if np.linalg.norm(spin) < 1e-12: raise ValueError('Replay needs a measured spin axis to recover geographic orientation')
    up0 = data['position']/np.linalg.norm(data['position'])
    spin_axis = spin/np.linalg.norm(spin)
    # Infer pole and longitude handedness from measured native coordinates,
    # rather than treating RAW y/z or VCRS signs as geographic conventions.
    candidates = []
    for pole_sign in (-1,1):
        north = pole_sign*spin_axis
        equator = up0-north*np.dot(north,up0)
        equator /= np.linalg.norm(equator)
        for mirror in (-1,1):
            east = mirror*np.cross(north,equator)
            def surface(lat,lng,ut,north=north,equator=equator,east=east):
                phi = math.radians(lat)
                delta = math.radians(lng-data['current_lng'])
                point = math.cos(phi)*(math.cos(delta)*equator+math.sin(delta)*east)+math.sin(phi)*north
                return rotate(point,spin,ut-data['now'])
            fit = (angle(surface(data['current_lat'],data['current_lng'],data['now']),up0)
                   +angle(surface(data['impact_lat'],data['impact_lng'],data['impact_ut']),impact_pos/np.linalg.norm(impact_pos)))
            candidates.append((fit,surface))
    fit,surface = min(candidates,key=lambda pair:pair[0])
    if fit*data['radius'] > 100:
        raise ValueError(f'Native coordinate calibration disagrees by {fit*data["radius"]:.1f} m')
    def target(ut): return surface(data['target_lat'],data['target_lng'],ut)
    def gap(ut):
        point,_ = after(ut-data['burn_ut'])
        return angle(point,target(ut))*data['radius']
    times = np.linspace(data['burn_ut'],data['impact_ut'],129)
    index = min(range(len(times)),key=lambda i:gap(times[i]))
    lo,hi = times[max(0,index-1)],times[min(len(times)-1,index+1)]
    for _ in range(32):
        first,second = lo+(hi-lo)/3,hi-(hi-lo)/3
        if gap(first) < gap(second): hi=second
        else: lo=first
    closest = min((lo,hi,(lo+hi)/2,data['burn_ut'],data['impact_ut']),key=gap)
    point,speed = after(closest-data['burn_ut'])
    up = point/np.linalg.norm(point)
    surface_speed = speed-np.cross(spin,point)
    vertical = np.dot(surface_speed,up)
    plane_now = abs(math.asin(np.clip(np.dot(plane,target(data['now'])),-1,1)))*data['radius']
    return dict(pre_pe_m=pre_peri-data['radius'],post_pe_m=post_peri-data['radius'],
                node_pe_error_m=post_peri-data['radius']-data['node_pe'],
                impact_fit_m=fit*data['radius'],target_plane_now_m=plane_now,
                target_pass_ut=float(closest),target_pass_miss_m=gap(closest),
                rotation_to_pass_deg=math.degrees(np.linalg.norm(spin)*(closest-data['now'])),
                pass_altitude_m=float(np.linalg.norm(point)-data['radius']),
                pass_above_target_terrain_m=float(np.linalg.norm(point)-data['radius']-data['target_terrain']),
                pass_vs_m_s=float(vertical),pass_hs_m_s=float(np.linalg.norm(surface_speed-vertical*up)),
                pass_before_impact_s=float(data['impact_ut']-closest))


if __name__ == '__main__':
    print(json.dumps(replay(parse_snapshot(Path(sys.argv[1]).read_text())),indent=2))
