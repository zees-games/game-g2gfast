# Stock-model props: counted, not drawn

A map's pakfile carries only the models its mapper added; a prop that names a model from the original game's archives is counted and not drawn (see [imported-maps.md](imported-maps.md#static-props)). `tools/stock_props_survey.py` ranks them from the `.bsp` files (model names are data; nothing is read from the private reference). Run on 2026-10-16: **345 stock models, 2083 placements, 1610 solid**.

**The finding that matters: 1,610 of 2,083 placements are solid.** A solid stock prop was neither drawn nor collided, so a route that depends on one (a crate to stand on, a rail, a fence) differed from the original. Most of the solid count is light fixtures and foliage, which no route uses.

## What is done (2026-10-17, `tools/stock_standins.py`)

- **Lights and foliage: `none`.** A lamp is not a surface anyone stands on, and foliage is decor (the survey's rules list bramble, cattail, fern, ivy, shrub, grass, trees and bushes by name).
- **Solid mass: a box, drawn and collided.** Crates, pallets, fences, rails, barrels, vehicles, train cars, containers, poles, pilings, concrete blocks and barriers, and rocks (`stock_standins.RULES`) become one axis box of the model's own hull, in a stand-in material (`wood/`, `metal/`, `concrete/`, `models/props_wasteland/rockcliff_standin`) that `textures/stock/substitutes.json` already maps to Kenney or ambientCG CC0 art, so the box is drawn as wood, metal, concrete or rock and takes the map's measured tint. It collides as `solid` 2 (the model's bounding box, which `prop_hulls` already builds), so what you see is what you stand on. The manifest's `static_props.stock_standins` counts them and `headless_imported` checks they were drawn.
- **Everything else is a written `none`, each with its why** (the last column of the survey): a window, arch or door has an opening a bbox would wall up; a pipe, truss or corner is far smaller than its box; a ladder is climbed (the map's `func_ladder` is the real one); a ramp's bbox is a block; the rest is small interior detail.
- **Not "on a route".** The 2026-10-16 decision said stand-ins only where solid and on a route. The importer cannot know a route on a map that winds, and an off-route solid box is what the original had, so every solid-mass prop with a hull gets one. Light and foliage carry the "none unless the look depends on it" half.

**The size comes from the archives, and only the size.** The hull is read from the MDL header in `/extra` at import time (`stock_archives.original`); no vertex, texture or collision shape is read and nothing read is written anywhere but the box's eight corners. A machine without the archives gets no stand-ins, as before.

**Base-engine models without a header (2026-10-19).** `/extra` still has only `cstrike_pak`, so 278 of the 467 placements with a stand-in rule (63 models) had no hull and were dropped. `stock_standins.hull` now resolves in three steps: the archive's own header (exact); else the median hull of the archive's variants in the same folder and family (`rockcliff05f` from `rockcliff07e`, the cluster rocks from their siblings: `_sibling`); else `ESTIMATES`, a written table of sizes from the name and the closest same-kind models in the archive (fences, rails and barriers run along y, a car is 80x190x64 like `car_nuke`). Every box is axis-aligned and centred on x and y, so **a variant or an estimate is a plausible box and not the original's size**; the manifest counts them apart (`static_props.stock_standins_estimated`) and the rest of this section's decisions are unchanged. 278 -> 0 placements with a rule and no box; 17 maps re-imported (6 of them are arena's, in `arena-surf-dm-maps`, not touched here). When the base engine's `hl2_misc` archive reaches `/extra`, the exact step wins automatically on a re-import.

**What this cannot do yet (still true for exact sizes):** `/extra` has only `cstrike_pak`, and the base engine's models (`props_wasteland/exterior_fence*`, `props_c17/handrail*`, `payphone001a`, `rockcliff*`, `rock_riverbed*`, `concrete_barrier001a`, vehicles, `dock01_pole*`) are in its `hl2_misc_*.vpk`. Those are the larger half of the solid-mass placements (279 of 510 with a stand-in rule) and keep being absent until that archive is on `/extra`; then re-import and the rules above apply to them unchanged. Maps re-imported so far: surf_lore, surf_dust2_2008_final, bhop_tesquo_v2; the rest pick the boxes up the next time they are imported (the importer is not run over every map here because `g2gfast-maps` is released as a whole).

| placed | solid | maps | model |
| --- | --- | --- | --- |
| 102 | 0 | 1 | `models/props/pi_shrub.mdl` |
| 85 | 9 | 4 | `models/props_foliage/ivy_01.mdl` |
| 66 | 66 | 3 | `models/props_interiors/lights_florescent01a.mdl` |
| 61 | 61 | 4 | `models/props_combine/weaponstripper.mdl` |
| 60 | 14 | 3 | `models/props_wasteland/light_spotlight01_lamp.mdl` |
| 57 | 57 | 2 | `models/props/cs_office/light_inset.mdl` |
| 51 | 51 | 4 | `models/props_lab/walllight001a.mdl` |
| 46 | 39 | 6 | `models/props/de_inferno/tree_small.mdl` |
| 40 | 31 | 4 | `models/props_foliage/cattails.mdl` |
| 33 | 0 | 2 | `models/props_wasteland/dockpole01a.mdl` |
| 32 | 32 | 2 | `models/props/de_dust/du_window_bridge.mdl` |
| 31 | 10 | 3 | `models/props/cs_militia/ladderrung.mdl` |
| 28 | 2 | 3 | `models/props_foliage/tree_deciduous_card_01.mdl` |
| 27 | 27 | 2 | `models/props_trainstation/payphone001a.mdl` |
| 24 | 24 | 1 | `models/props_lab/lab_flourescentlight001a.mdl` |
| 22 | 22 | 2 | `models/props_wasteland/rockcliff_cluster02b.mdl` |
| 22 | 22 | 4 | `models/props_wasteland/exterior_fence002e.mdl` |
| 22 | 22 | 3 | `models/props/de_dust/du_crate_64x64.mdl` |
| 21 | 21 | 4 | `models/props_c17/light_floodlight02_off.mdl` |
| 21 | 21 | 2 | `models/props_c17/handrail04_medium.mdl` |
| 20 | 15 | 4 | `models/props/de_dust/du_palm_tree01_skybx.mdl` |
| 20 | 20 | 1 | `models/props/de_dust/palm_tree_head_skybox.mdl` |
| 20 | 0 | 1 | `models/props/de_prodigy/prodgrassa.mdl` |
| 19 | 14 | 6 | `models/props/de_inferno/tree_large.mdl` |
| 19 | 19 | 2 | `models/props_wasteland/light_spotlight02_lamp.mdl` |
| 19 | 0 | 1 | `models/props/de_inferno/largebush03.mdl` |
| 18 | 18 | 1 | `models/props/de_train/light_security.mdl` |
| 18 | 0 | 1 | `models/props/de_inferno/largebush01.mdl` |
| 17 | 0 | 1 | `models/props/de_nuke/industriallight01.mdl` |
| 16 | 16 | 2 | `models/props_docks/dock01_pole01a_256.mdl` |
| 16 | 16 | 3 | `models/props/cs_militia/tree_large_militia.mdl` |
| 16 | 16 | 1 | `models/props/de_cbble/cb_wndsng16.mdl` |
| 15 | 9 | 3 | `models/props/cs_militia/fern01lg.mdl` |
| 15 | 15 | 4 | `models/props/cs_office/exit_ceiling.mdl` |
| 14 | 14 | 2 | `models/props/de_dust/du_dome_d2b.mdl` |
| 14 | 14 | 1 | `models/props/de_prodigy/prodcratesb.mdl` |
| 13 | 2 | 2 | `models/props/cs_militia/trees3.mdl` |
| 13 | 10 | 2 | `models/props/cs_militia/fern01.mdl` |
| 12 | 12 | 3 | `models/props/de_train/pallet_barrels.mdl` |
| 12 | 12 | 2 | `models/props_canal/rock_riverbed01d.mdl` |

The rest, with each model's class and decision, are in the tool's output.
