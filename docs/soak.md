# Bot soak

`./game.sh soak [map] [minutes]` runs `tools/soak.tscn`: four of the game's course-riding bots (`game/g2g_bots.gd`) on one map, driven by dot-bot's `DotBotSoak` with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts. The report is `.godot/test-logs/soak-<map>.json` and one `SOAK {...}` line. There is no combat here, so the kill check is off. There is no navigation mesh either, so off-nav and unreachable are off; a bot rides its stage or the route, and the course puts it back when it arrives, falls or runs out of `RIDE_SECONDS`.

First run, 2026-10-22, 0.5 simulated minutes per map, 4 bots, 62 of the 64 maps: 32 pass, 30 fail, all failures `stuck` (a bot within one radius for over 10 s). Tick cost is not the problem: p95 is 0 to 4 ms at 128 Hz, worst single tick 91 ms (surf_lt_omnific, map load or plan step), object and memory growth within limits everywhere.

- Only surf_beginner (pilot, 28 arrivals) and surf_intro (24) actually complete rides. Every other map is the rule-based route bot, and none of them arrived once in 30 s.
- Put back every tick (the course reports a fall at the stage start itself, 900 to 3840 puts back in 3840 ticks): bhop_arcane_v2, bhop_elate, bhop_exodus, bhop_fury_2, bhop_interloper, bhop_japan, bhop_pandora2_fix, bhop_pit, bhop_tesquo_v2, kz_bhop_badg3s, surf_omnibus.
- Stuck without being put back: bhop_aztec, bhop_badges2, bhop_crash_egypt, bhop_eazy, bhop_lego2, bhop_monster_jam, bhop_platformer_fxd, bunnyhop_pro, buses_from_hell_fixed, kz_bhop_lucid, kz_bhop_yonkoma, surf_animals, surf_aquaflow, surf_hologram, surf_interference, surf_lt_omnific, surf_mesa, surf_rookie, surf_vegetables.
- Not soaked: bhop_mario_fxd (not in the map catalogue) and surf_greensway (aborts the process on a thread call, `propagate_notification()` off the main thread, while loading).
- Pass: the three built-in maps, bhop_ananas, badges, badges_mini, eazy_v2, epiphany, evolve, frotinity2, fur, grove, lego3, nature, ocean, overthinker, sqee, supernova, underground_crypt, surf_arcade, beginner, beginner2, eclipse, intro, kitsune, life_of_duck, lore, lt_unicorn, quilavar, stonework3, summit, year3000.
