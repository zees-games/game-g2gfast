# The most popular surf and bunny-hop maps on GameBanana, and which we have

Measured 2026-10-05 for nightly item gb-maps-1. This is the list the imports work down; re-run it rather than trusting it after a few months, because view counts move.

## How it was measured

GameBanana's search API (`Util/Search/Results`) ranks by relevance, not popularity, which is what the first batch was chosen from. The category index ranks properly: `https://gamebanana.com/apiv11/Mod/Index?_nPerpage=50&_nPage=<n>&_aFilters[Generic_Category]=<id>&_sSort=Generic_MostViewed` (or `Generic_MostLiked`). The two categories are **5558 Surf Style** (2,270 maps, including its children 5626 Combat Surf and 5627 Skill Surf) and **5568 Bunny Hop** (2,977 maps), both children of 5535, the maps section of [GameBanana game 2](https://gamebanana.com/games/2). The first 100 of each category by views and by likes were fetched: 307 distinct maps.

**Skipped as a newer engine version (VBSP 21 and later): 0.** Both categories belong to game 2, every one of the 307 records says so, and all twelve archives downloaded so far held a VBSP 19 or 20 file. The newer releases have their own sections on the site, which this list never reads.

"Have it" means a `maps/zones/<id>.json` whose attribution names that page, or a .bsp of that name under `inspirations/g2gfast/`. A page that matches only by a near name is called a variant.

## Top 50 by views

| # | Page | Map | Category | Views | Likes | Status |
| --- | --- | --- | --- | ---: | ---: | --- |
| 1 | [125558](https://gamebanana.com/mods/125558) | bhop_monster_jam | Bunny Hop | 179,415 | 27 | held (`bhop_monster_jam`) |
| 2 | [121522](https://gamebanana.com/mods/121522) | surf_10x_final | Surf Style | 139,443 | 28 | imported 2026-10-05, not a course (`surf_10x_final`) |
| 3 | [122076](https://gamebanana.com/mods/122076) | surf_forbidden_ways_reloaded | Surf Style | 116,582 | 32 | imported 2026-10-05, not a course (`surf_forbidden_ways_reloaded`) |
| 4 | [121524](https://gamebanana.com/mods/121524) | surf_10x_reloaded_fix | Surf Style | 112,145 | 33 | imported 2026-10-05, not a course (`surf_10x_reloaded_fixed`) |
| 5 | [122092](https://gamebanana.com/mods/122092) | surf_fruits | Surf Style | 111,805 | 17 | imported 2026-10-05, not a course (`surf_fruits`) |
| 6 | [123284](https://gamebanana.com/mods/123284) | surf_xiv_v2a | Surf Style | 97,595 | 35 | imported 2026-10-05, not a course (`surf_xiv_v2a`) |
| 7 | [122505](https://gamebanana.com/mods/122505) | surf_mai_remix | Surf Style | 79,729 | 33 | imported 2026-10-05, not a course (`surf_mai_remix`) |
| 8 | [122382](https://gamebanana.com/mods/122382) | surf_kitsune | Surf Style | 78,483 | 11 | held (`surf_kitsune`) |
| 9 | [122206](https://gamebanana.com/mods/122206) | surf_greatriver_xdre4m | Surf Style | 77,956 | 8 | imported 2026-10-05, not a course (`surf_greatriver_xdre4m`) |
| 10 | [122953](https://gamebanana.com/mods/122953) | surf_ski_2 | Surf Style | 77,612 | 2 | imported 2026-10-05, not a course (`surf_ski_2`) |
| 11 | [121714](https://gamebanana.com/mods/121714) | surf_beginner | Surf Style | 76,150 | 12 | imported 2026-10-05 (`surf_beginner`) |
| 12 | [121530](https://gamebanana.com/mods/121530) | surf_110b_austinpowers | Surf Style | 74,690 | 15 | imported 2026-10-05, not a course (`surf_110b_austinpowers`) |
| 13 | [122470](https://gamebanana.com/mods/122470) | surf_lt_omnific | Surf Style | 70,473 | 38 | imported 2026-10-09 (`surf_lt_omnific`) |
| 14 | [122424](https://gamebanana.com/mods/122424) | surf_legends | Surf Style | 69,947 | 15 | imported 2026-10-09, not a course (`surf_legends`) |
| 15 | [122542](https://gamebanana.com/mods/122542) | Surf_Mesa | Surf Style | 66,169 | 11 | held (`surf_mesa`) |
| 16 | [124461](https://gamebanana.com/mods/124461) | bhop_arcane_v1 | Bunny Hop | 65,615 | 14 | variant held (bhop_arcane_v2, page 124462) |
| 17 | [122463](https://gamebanana.com/mods/122463) | surf_lore | Surf Style | 60,715 | 38 | imported 2026-10-09 (`surf_lore`) |
| 18 | [124524](https://gamebanana.com/mods/124524) | bhop_badges | Bunny Hop | 60,554 | 23 | held (`bhop_badges`) |
| 19 | [122158](https://gamebanana.com/mods/122158) | surf_greatriver | Surf Style | 57,739 | 19 | imported 2026-10-09, not a course (`surf_greatriver`; VBSP 19, found bsp_read's v19 leaf bug) |
| 20 | [123222](https://gamebanana.com/mods/123222) | surf_vegetables | Surf Style | 56,526 | 17 | imported 2026-10-09, a course: 9 gates, round jails dropped (`surf_vegetables`) |
| 21 | [121698](https://gamebanana.com/mods/121698) | surf_bathroom_final | Surf Style | 54,769 | 26 | imported 2026-10-09, not a course (`surf_bathroom_final`) |
| 22 | [121606](https://gamebanana.com/mods/121606) | surf_akai_final | Surf Style | 52,637 | 18 | imported 2026-10-09, not a course (`surf_akai_final`) |
| 23 | [121787](https://gamebanana.com/mods/121787) | surf_buck-wild | Surf Style | 52,359 | 18 | imported 2026-10-09, not a course (`surf_buck_wild`) |
| 24 | [121976](https://gamebanana.com/mods/121976) | surf_eclipse | Surf Style | 50,855 | 33 | imported 2026-10-09 (`surf_eclipse`) |
| 25 | [122075](https://gamebanana.com/mods/122075) | surf_forbidden_ways_2nd | Surf Style | 49,100 | 29 | imported 2026-10-09, not a course (`surf_forbidden_ways_2nd`) |
| 26 | [122202](https://gamebanana.com/mods/122202) | surf_greatriver_v4 | Surf Style | 49,026 | 14 | imported 2026-10-09, not a course (`surf_greatriver_v4`) |
| 27 | [122673](https://gamebanana.com/mods/122673) | surf_omnibus | Surf Style | 48,312 | 32 | imported 2026-10-09 (`surf_omnibus`) |
| 28 | [124915](https://gamebanana.com/mods/124915) | bhop_eazy_v2 | Bunny Hop | 46,821 | 13 | imported 2026-10-09, a course: 5 colour sections (`bhop_eazy_v2`) |
| 29 | [122824](https://gamebanana.com/mods/122824) | surf_rebel_resistance_final2 | Surf Style | 46,263 | 12 | imported 2026-10-09 as final3, the page's file; not a course (`surf_rebel_resistance_final3`) |
| 30 | [126426](https://gamebanana.com/mods/126426) | bunnyhop_pro | Bunny Hop | 46,183 | 6 | imported 2026-10-09, a practice yard with no finish (`bunnyhop_pro`) |
| 31 | [124913](https://gamebanana.com/mods/124913) | bhop_eazy | Bunny Hop | 45,860 | 11 | held, not a course (`bhop_eazy`) |
| 32 | [124977](https://gamebanana.com/mods/124977) | bhop_exodus | Bunny Hop | 45,366 | 26 | imported 2026-10-09 (`bhop_exodus`) |
| 33 | [122985](https://gamebanana.com/mods/122985) | surf_skyworld | Surf Style | 44,124 | 19 | imported 2026-10-09, not a course (`surf_skyworld`) |
| 34 | [123141](https://gamebanana.com/mods/123141) | surf_thriller | Surf Style | 43,971 | 3 | imported 2026-10-09, not a course (`surf_thriller`) |
| 35 | [126077](https://gamebanana.com/mods/126077) | bhop_sQee | Bunny Hop | 42,138 | 18 | imported 2026-10-09, a course: 10 levels (`bhop_sqee`) |
| 36 | [122478](https://gamebanana.com/mods/122478) | surf_machine2 | Surf Style | 41,944 | 15 | imported 2026-10-09, not a course (`surf_machine2`) |
| 37 | [122520](https://gamebanana.com/mods/122520) | surf_matrix_v8 | Surf Style | 40,365 | 8 | imported 2026-10-09, not a course (`surf_matrix_v8`) |
| 38 | [137677](https://gamebanana.com/mods/137677) | surf_adverse | Combat Surf | 39,329 | 35 | imported 2026-10-09, not a course (`surf_adverse`) |
| 39 | [122860](https://gamebanana.com/mods/122860) | surf_rookie | Surf Style | 38,817 | 4 | imported 2026-10-09, a course: 18 stages (`surf_rookie`) |
| 40 | [121629](https://gamebanana.com/mods/121629) | Surf_Animals | Surf Style | 38,552 | 19 | imported 2026-10-09, credit only: a race-then-fight map driven by outputs (`surf_animals`) |
| 41 | [122956](https://gamebanana.com/mods/122956) | Surf_ski_2_source | Surf Style | 37,536 | 3 | imported 2026-10-09, not a course; a different file from surf_ski_2 (`surf_ski_2_source`) |
| 42 | [121540](https://gamebanana.com/mods/121540) | surf_29_12_06 | Surf Style | 37,029 | 22 | imported 2026-10-09, not a course (`surf_29_12_06`) |
| 43 | [123134](https://gamebanana.com/mods/123134) | surf_the_gloaming | Surf Style | 36,153 | 32 | imported 2026-10-09, not a course (`surf_the_gloaming`) |
| 44 | [121962](https://gamebanana.com/mods/121962) | surf_dust2_2008_final | Surf Style | 35,615 | 7 | imported 2026-10-09, not a course (`surf_dust2_2008_final`) |
| 45 | [126499](https://gamebanana.com/mods/126499) | kz_bhop_yonkoma | Bunny Hop | 35,327 | 35 | imported 2026-10-09, no finish (`kz_bhop_yonkoma`) |
| 46 | [137687](https://gamebanana.com/mods/137687) | surf_japan_ptad | Combat Surf | 34,426 | 18 | imported 2026-10-09, not a course (`surf_japan_ptad`) |
| 47 | [126445](https://gamebanana.com/mods/126445) | kz_bhop_badg3s | Bunny Hop | 33,149 | 41 | imported 2026-10-09 (`kz_bhop_badg3s`) |
| 48 | [125304](https://gamebanana.com/mods/125304) | bhop_japan | Bunny Hop | 32,661 | 37 | imported 2026-10-09 (`bhop_japan`) |
| 49 | [123298](https://gamebanana.com/mods/123298) | surf_year3000 | Surf Style | 32,628 | 8 | held (`surf_year3000`) |
| 50 | [122497](https://gamebanana.com/mods/122497) | surf_machine_remix_final | Surf Style | 32,250 | 12 | imported 2026-10-09, not a course (`surf_machine_remix_final`) |

## Most liked, outside that list

Likes are a second view, and a useful one because views accumulate with age: 35 of the top 50 by views were uploaded between 2005 and 2009. These are the fifteen most liked that are not in the top 50 by views.

| Page | Map | Category | Views | Likes | Status |
| --- | --- | --- | ---: | ---: | --- |
| [125285](https://gamebanana.com/mods/125285) | bhop_interloper | Bunny Hop | 16,828 | 46 | held (`bhop_interloper`) |
| [124748](https://gamebanana.com/mods/124748) | Bhop_crash_egypt | Bunny Hop | 19,000 | 36 | imported 2026-10-10 (`bhop_crash_egypt`) |
| [125694](https://gamebanana.com/mods/125694) | bhop_overthinker | Bunny Hop | 14,881 | 34 | imported 2026-10-10 (`bhop_overthinker`) |
| [125409](https://gamebanana.com/mods/125409) | bhop_lego3 | Bunny Hop | 10,791 | 33 | imported 2026-10-10 (`bhop_lego3`) |
| [124525](https://gamebanana.com/mods/124525) | bhop_badges2 | Bunny Hop | 26,129 | 32 | imported 2026-10-10 (`bhop_badges2`) |
| [122641](https://gamebanana.com/mods/122641) | surf_ny_advance | Surf Style | 30,095 | 31 | imported 2026-10-10, not a course (`surf_ny_advance`) |
| [122471](https://gamebanana.com/mods/122471) | surf_lt_unicorn | Surf Style | 26,670 | 31 | imported 2026-10-10 (`surf_lt_unicorn`) |
| [125646](https://gamebanana.com/mods/125646) | bhop_ocean | Bunny Hop | 10,933 | 30 | imported 2026-10-10 (`bhop_ocean`) |
| [122711](https://gamebanana.com/mods/122711) | surf_pavilion | Surf Style | 18,078 | 29 | imported 2026-10-10, not a course (`surf_pavilion`) |
| [123157](https://gamebanana.com/mods/123157) | surf_torque2 | Surf Style | 17,330 | 27 | imported 2026-10-10, not a course (`surf_torque2`) |
| [125089](https://gamebanana.com/mods/125089) | bhop_frotinity2 | Bunny Hop | 7,461 | 27 | imported 2026-10-10 (`bhop_frotinity2`) |
| [125470](https://gamebanana.com/mods/125470) | bhop_lost_world | Bunny Hop | 30,011 | 26 | downloaded 2026-10-10, not imported (see below) |
| [123224](https://gamebanana.com/mods/123224) | surf_velocity | Surf Style | 24,088 | 26 | imported 2026-10-10, not a course (`surf_velocity`) |
| [125408](https://gamebanana.com/mods/125408) | bhop_lego2 | Bunny Hop | 21,756 | 26 | held, not a course (`bhop_lego2`) |
| [126473](https://gamebanana.com/mods/126473) | kz_bhop_lucid | Bunny Hop | 14,183 | 26 | imported 2026-10-10, not a course (`kz_bhop_lucid`) |

## What the most-viewed surf maps turned out to be

**Nine of the first ten not-yet-held maps by views are not courses.** The surf maps with the most views are the combat surf of 2006-2009: buyzones or weapon buttons, jails, and every teleport aimed back at a spawn or a ramp top. They import, draw and collide like any other map and are credited, but there is no line a run could end at, so each is in `NOT_COURSES` in `examples/headless_imported.gd` and its zones file says why. Whether combat maps belong in a timer server's rotation at all is a call for later; nothing lists them in `game.yml`.

For the next batch, work down the likes list as well as the views list: skill-surf and bunny-hop pages (`surf_lore`, `surf_lt_omnific`, `surf_eclipse`, `surf_omnibus`, `kz_bhop_badg3s`, `bhop_japan`, `kz_bhop_yonkoma`, `bhop_exodus`) are where the courses are.

## The batch imported 2026-10-05, ranked by what is wrong with it

Worst first. Own is the share of a map's triangles drawn in a texture its own pakfile carried; stand-ins adds `G2GStockSubstitutes`' replacements for the stock textures it did not carry, and the rest is the prototype grid. Props are static props placed against those the map did not carry (and so are not drawn). This list feeds g2g-maps-stock-1.

| Map | Course? | Own | With stand-ins | Props missing | Notes from the frames |
| --- | --- | ---: | ---: | --- | --- |
| `surf_10x_reloaded_fixed` | no (combat) | 0.0% | 0.0% | 0 of 0 | all grid; spawn platform reads, the ramps beyond are grey |
| `surf_10x_final` | no (combat) | 0.0% | 0.2% | 0 of 0 | all grid |
| `surf_ski_2` | no (combat) | 0.0% | 0.2% | 0 of 0 | all grid; compiled without lighting (0 lit faces); its loose credits decal is outside the pakfile |
| `surf_mai_remix` | no (combat) | 0.0% | 0.7% | 14 of 14 | all grid |
| `surf_greatriver_xdre4m` | no (combat) | 0.0% | 2.4% | 3 of 3 | all grid |
| `surf_grave_reloaded` | no (combat) | 0.0% | 3.5% | 22 of 22 | all grid; the orbit frames are lost in the game's fog |
| `surf_fruits` | no (round-picked stages) | 23.0% | 26.2% | 72 of 112 | dark, and the spawn frames show large black sawtooth shapes nobody has explained yet |
| `surf_xiv_v2a` | no (minigames) | 3.9% | 29.5% | 39 of 39 | from the spawn the frame is mostly open sky with one slab and a fence; not investigated |
| `surf_forbidden_ways_reloaded` | no (combat) | 3.3% | 31.0% | 6 of 6 | readable spawn deck, glass and water textured |
| `surf_quilavar` | yes: start, finish | 38.5% | 38.5% | 0 of 0 | tiled spawn chamber in its own textures, black openings |
| `surf_beginner` | yes: start, 7 stages, finish | 0.0% | 49.1% | 2 of 2 | wooden spawn deck with the author's sign, readable |
| `surf_110b_austinpowers` | no (combat) | 52.8% | 52.8% | 54 of 54 | compiled without lighting (0 lit faces), so everything is flat white; one magenta floor that may be the map's own |

No map in the batch spawned a player in solid, and every one passes `headless_imported` (1,906 checks over 42 maps).

## Downloaded and not yet imported

In `inspirations/g2gfast/pending/` with their archives in `inspirations/g2gfast/`, and no credit file yet:

- `surf_lt_omnific` ([122470](https://gamebanana.com/mods/122470), nyro, qr and checkem): a skill course in three authors' sections, each of t1..t6, and like `surf_kitsune` it steers progression with `AddOutput targetname` and filters rather than labels. Needs its teleport graph read the way kitsune's was.
- `surf_legends` ([122424](https://gamebanana.com/mods/122424), SintaxError): combat surf (jails, weapon spawner buttons). Credit-only import, like the rest of this batch.

## The batch imported 2026-10-09

Seven courses from both lists and the last pending combat map: `bhop_japan`, `bhop_exodus`, `kz_bhop_badg3s`, `surf_omnibus`, `surf_lore` and `surf_eclipse` are timed from their own spawns and finish teleports or triggers; `kz_bhop_yonkoma` is an adventure climb map with a spawn and no finish (its logic is buttons and timed doors, and nothing in it marks the end); `surf_legends` is combat surf, credit only. Every one is a VBSP 20 file. Two importer changes came out of it: repeated output keys are kept (the trap delays on bhop_japan, bhop_interloper and bhop_arcane_v2 sat in a trigger's second `OnTrigger`), and `round_teleports` drops a race map's start-disabled jail and level-select teleports by name. `surf_lt_omnific` followed the same day: eighteen sections by three mappers in an interleaved order read from its landmark teleports, timed from the first section's start to the ending room, with no stage lines yet.

## The batch imported 2026-10-10

The thirteen most-liked maps outside the top 50 by views (gb-maps-2). Twelve imported, each with an attribution and what was read and why in its zones file; one left out.

- **Courses, timed from the map's own start to its own finish:** `bhop_overthinker` (labels its zones `mod_zone_start` / `mod_zone_end`, plus a bonus), `surf_lt_unicorn` (labels six stages as `stage_startzone_NN`, a finish and three bonuses), `bhop_crash_egypt` (32 sections; the finish is the warp sphere past the last one), `bhop_lego3` (the end figure's finish animation), `bhop_ocean` (the spawn teleports to a start island; the finish is the island with the ending song), `bhop_badges2` (the confetti trigger), `bhop_frotinity2` (eight mappers' stages, finished at `finishend`; no stage lines yet).
- **Combat or race rounds, credit only and `kind: arena`:** `surf_ny_advance`, `surf_pavilion`, `surf_torque2`, `surf_velocity` (team spawns, equipment, jails, scored levels).
- **A spawn and no finish:** `kz_bhop_lucid`, a hub of four coloured routes whose finish opens when a counter reaches four, which this game does not run.
- **Not imported:** `bhop_lost_world` (in `inspirations/g2gfast/pending/`): an adventure map whose route runs through timed doors ("You have 8 seconds before door closes"), button-enabled teleports and dream sequences, all of them the map's logic.

What the importer learned from them: boosters (a thin `trigger_multiple` whose OnEndTouch sets `basevelocity`) are pushes given on leaving, which ten maps use and none was reading; `stage_startzone_NN` and the `mod_` prefix are labels; `ignore_labels` leaves a labelled zone unread with a reason (unicorn's bonus 1, a collectables challenge); and a pit trimmed back off an arrival keeps a tick's depth.


## Extended 2026-10-13: the next most liked, and the next by views

Both lists above were used up, so chk-maps fetched pages 1-4 (200 maps) of each category by views and by likes (595 distinct maps, every BSP downloaded VBSP 20 from the genre's classic map format; no newer-format file among them). The ten most liked that we did not have were the batch:

| Page | Map | Category | Views | Likes | Status |
| --- | --- | --- | ---: | ---: | --- |
| [125590](https://gamebanana.com/mods/125590) | bhop_nature | Bunny Hop | 9,761 | 26 | imported 2026-10-13: spawn room to level1, finish at the credit trigger past level22 (`bhop_nature`) |
| [122709](https://gamebanana.com/mods/122709) | surf_parrot_selector | Surf Style | 17,857 | 25 | imported 2026-10-13, not a course: team minigame, round jails dropped (`surf_parrot_selector`) |
| [124933](https://gamebanana.com/mods/124933) | bhop_elate | Bunny Hop | 9,549 | 25 | imported 2026-10-13: sea then cave, finish on the mapper's END floor (`bhop_elate`) |
| [122644](https://gamebanana.com/mods/122644) | surf_ny_bigloop_2008 | Surf Style | 26,483 | 24 | imported 2026-10-13, not a course; the archive ships `surf_ny_bigloop_2008a` |
| [122168](https://gamebanana.com/mods/122168) | surf_greatriver_awesome | Surf Style | 14,513 | 24 | downloaded, not imported (pending/): a joke reskin of surf_greatriver, unlit |
| [125964](https://gamebanana.com/mods/125964) | bhop_shutdown2 | Bunny Hop | 14,288 | 24 | downloaded, not imported (pending/): 41% prototype grid, chapter graph unread |
| [126278](https://gamebanana.com/mods/126278) | bhop_umbra | Bunny Hop | 10,195 | 24 | downloaded, not imported (pending/): route switches the player's classname |
| [126281](https://gamebanana.com/mods/126281) | bhop_underground_crypt | Bunny Hop | 18,413 | 24 | imported 2026-10-13: start room, finish at the credit trigger past finale_04 (`bhop_underground_crypt`) |
| [126357](https://gamebanana.com/mods/126357) | bhop_woodenspace | Bunny Hop | 10,011 | 24 | downloaded, not imported (pending/): no finish marked |
| [122741](https://gamebanana.com/mods/122741) | surf_pox | Surf Style | 29,739 | 23 | imported 2026-10-13, not a course (`surf_pox`; its black sky is its own) |

**Next by likes**, not held: surf_spectrum [123037] (23), bhop_communityjump [124722] (23), surf_ny_exploder_prime [122646] (21), Surf_Elements_beta3 [121990] (21), bhop_angst [303411] (21), bhop_cw_journey [124781] (21), surf_lithium2 [122445] (20), Surf_Gurus [122228] (20), surf_ember [122002] (20), surf_buck-around [121783] (20), surf_buck-ed_up [121784] (20), bhop_relinquished_fixx [125839] (20).

**Next by views** (ranks 51 onwards, not held): surf_ny_platinum [122651] (30,756), surf_rebel_resistance_pack [122826], surf_4fun [121545], bhop_miku [125530], surf_ag_texture_final [121589], surf_akai_f1n4l [121605], surf_spongebob [123039], bhop_training_fun [126237], surf_simpsons_source [122938], surf_ski [122949], bhop_amor [124424]. Like the top 50, most of the surf ones are 2006-2009 combat maps; the liked bhop pages are where the courses are.

## Imported 2026-10-20

- [124957](https://gamebanana.com/mods/124957) `bhop_epiphany` (wet; the map's own text reads "By Nate"; 40 MB archive, a single VBSP 20 file): a nine-level course, 94.2% of its triangles drawn with stand-ins. The 60 spawns stand in a holding room whose floor teleports to `cpb`, so the start is a box round `cpb`; the finish is the trigger in the `cp_end` room that shows the map's closing text. Its checkpoints are class-renaming triggers behind class-filtered teleports, which the importer drops on its own (151 of them), leaving the per-level pits. The page states Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 and asks to be contacted before a redistribution; it does not forbid sharing. Credited here and on screen, with a removal-on-request offer in g2gfast-maps's README. Not played end to end: no gate-by-gate walk exists for it (`GATED_COURSES`), and the level order past `cpb` was read from the destination names, not driven.
- [137698](https://gamebanana.com/mods/137698) `surf_snipers_island` (Loller Dan; CC BY-NC-ND 4.0; page checked 2026-10-20, nothing against porting): combat map, `kind: arena`, so it lives in `arena-surf-dm-maps` (641555d); only its zones file with the attribution is here.

## Imported 2026-10-22

All eleven downloads are VBSP 20; the pages all state CC BY-NC-ND 4.0 and none says anything against porting, so each is credited here and on screen, with a removal-on-request offer in g2gfast-maps's README.

- [303411](https://gamebanana.com/mods/303411) `bhop_angst` (Proxychains): the map labels its own start and finish zones, so the zones file is credit only; the secret track is left out. A third of its triangles are its own materials over stock flat developer colours it did not carry, listed as `none` in `textures/stock/substitutes.json`.
- [124424](https://gamebanana.com/mods/124424) `bhop_amor` (roma): two tracks. The pro route starts in a box at the spawn-side gate and ends at the teleport to `map_finish`; the noob route starts round `noob1` and ends at the last teleport by the noob finish. Neither track was driven end to end.
- [122445](https://gamebanana.com/mods/122445) `surf_lithium2` (copy-mark): start from `level1` (the spawn room teleports there) down to the floor 688 units under it, where the spawn stands; the finish is a box on the end triggers in the winner room, which start disabled behind team filters; the end-of-round teleport is dropped.
- [122002](https://gamebanana.com/mods/122002) `surf_ember` (Skar): start round `1ENTER`, finish at the teleports to `JAILTOP`; the round-timer teleports (`Timesup*`, `YOULOSE`) are dropped.
- [126237](https://gamebanana.com/mods/126237) `bhop_training_fun` (Soapy Soap): a practice yard with no finish; credit only, and listed in `headless_imported`'s `NOT_COURSES`.

Downloaded and sent to `inspirations/g2gfast/pending/` (reasons in its README): `surf_spectrum` (123037), `surf_gurus` (122228), `bhop_relinquished_fixx` (125839), `bhop_miku` (125530), `bhop_cw_journey` (124781), `bhop_communityjump` (124722). Not downloaded: `Surf_Elements_beta3` (121990), a team minigame map that belongs with the arena maps, and `surf_ny_exploder_prime` (122646), already on the arena surf list.
