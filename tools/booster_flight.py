"""Booster flight model for route_plan.py: what a launch off a jump pad reaches.

Mirrors the game, not a formula: `G2GMapMechanics` adds a `leave` push to the velocity when the hull leaves
the trigger, the player jumped on the pad (JUMP_V up) so the flight starts at JUMP_V plus the push, gravity is
`sv_gravity` per tick, and the air is `DotFpsMotor.accelerate` with `sv_airaccelerate` and the air wish cap.
The strafe is the route bot's: it alternates sides at right angles to its velocity (`G2GRouteBot._air`), the
most any wish adds, so the flight gains speed while it falls. Units are game units (u, u/s), as the planner's.
"""
import math

TICK = 128.0         # sv tick rate (G2GGameState.tick_rate)
AIR_ACCEL = 1000.0   # sv_airaccelerate
AIR_CAP = 30.0       # sv_maxairwishspeed
WISH = 250.0         # the wish speed of a full move (sv_maxspeed)
MAX_VEL = 3500.0     # sv_maxvelocity
_cache = {}


def _accelerate(vx, vz, dx, dz, dt):
    add = AIR_CAP - (vx * dx + vz * dz)
    if add <= 0.0:
        return vx, vz
    s = min(AIR_ACCEL * WISH * dt, add)
    return vx + dx * s, vz + dz * s


def flight(launch_vy, speed, rise, gravity=800.0, strafe=True):
    """Horizontal distance (u) and time (s) of a flight that starts at `speed` u/s along +x and `launch_vy` up,
    until it comes down through `rise` units above the take-off height. (0, 0) when it never gets that high."""
    key = (round(launch_vy), round(speed), round(rise), gravity, strafe)
    if key in _cache:
        return _cache[key]
    dt = 1.0 / TICK
    vx, vz, vy = speed, 0.0, launch_vy
    x = z = y = 0.0
    side = 1.0
    peaked = False
    t = 0.0
    res = (0.0, 0.0)
    for _ in range(int(TICK * 60)):
        if strafe:
            sp = math.hypot(vx, vz)
            # a wish at right angles to the velocity, side alternating, as the bot's strafe
            dx, dz = (-vz / sp * side, vx / sp * side) if sp > 0.5 else (0.0, side)
            vx, vz = _accelerate(vx, vz, dx, dz, dt)
            sp = math.hypot(vx, vz)
            if sp > MAX_VEL:
                vx, vz = vx * MAX_VEL / sp, vz * MAX_VEL / sp
            side = -side
        vy -= gravity * dt
        y += vy * dt; x += vx * dt; z += vz * dt; t += dt
        if vy < 0:
            peaked = True
        if peaked and y <= rise:
            res = (math.hypot(x, z), t) if y <= rise and max(y, 0) >= 0 else (0.0, 0.0)
            break
    _cache[key] = res
    return res


def reach(launch_vy, speed, rise, safety=1.0, gravity=800.0, strafe=True):
    """The furthest landing distance on a top `rise` above the pad that the launch can aim at (shorter ones are braked into)."""
    return safety * flight(launch_vy, speed, rise, gravity, strafe)[0]


if __name__ == '__main__':
    import sys
    vy = float(sys.argv[1]) if len(sys.argv) > 1 else 1302.0
    for rise in (-600, -61, 0, 200, 435):
        print(rise, 'strafe %.0f u in %.2f s' % flight(vy, 250.0, rise), 'straight %.0f u' % flight(vy, 250.0, rise, strafe=False)[0])
