# game-g2gfast docs

One subject per file. [CLAUDE.md](../CLAUDE.md) has the rules in one line each; these files have the reasoning.

| File | What it covers |
| --- | --- |
| [movement.md](movement.md) | Genre units and the one conversion boundary, auto-bhop and the styles, the prestrafe, movement effects as styles, the player stack (spawns per track), third person, ladders and water, ramps and the motor's open problems, the hull numbers |
| [timer.md](timer.md) | What taints a run, the record's ghost and replays, stages and restarts and R, records, standings, the SQL store, points, statistics, how a run replicates |
| [maps.md](maps.md) | The three hand-built maps: the default map, geometry and zones from one list, `export_zones`, pits per route, the stages map, surface roles, the survey |
| [routes.md](routes.md) | What a jump reaches (RUN and CHAIN), every bonus route and how its bot drives it, the route bot and replay follower for imported maps |
| [imported-maps.md](imported-maps.md) | The importer: scale and axes, zones and the zones file, pits, spawns, the solid as convex brushes, roles from slope, what brush entities do, static props, what is not imported |
| [brush-entities.md](brush-entities.md) | Every brush entity class and what the importer and `G2GMapMechanics` make of it |
| [map-rendering.md](map-rendering.md) | Lighting, the lightmap atlas, translucency, glass and water, stand-in textures and the prototype grid, skies, static prop lighting, the surface limit, the preview tool |
| [map-delivery.md](map-delivery.md) | The catalogue with no list, g2gfast-maps and owners, pack versions, the map-change protocol and the trusted template, rotation and the map list |
| [netcode.md](netcode.md) | The bridge, the movement config on the wire, the tick rate, drawing between ticks, what a connected player sees, wire rules, hunters, what a full server costs |
| [client.md](client.md) | Field of view, the camera and the player's own body, avatars, keys, the pointer, menus (dot-menu), the HUD, the flashlight, presentation and sound, the chat box, the zone editor |
| [services.md](services.md) | Admin tools (blind, beacon), chat and voice, the vote and its clock, the server browser, identity, statistics |
| [modes.md](modes.md) | Layers over the timer: deathmatch, the fire bit, hunters, practice blocks, effects, spectating |
| [testing.md](testing.md) | The suites and what each proves, lists asserted both ways, checks that could not fail, the tools |
| [history.md](history.md) | Bugs this game found and how they looked |
| [gamebanana-ranking.md](gamebanana-ranking.md) | Candidate maps for import, ranked, and why each was or was not taken |
