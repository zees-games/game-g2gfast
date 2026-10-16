# Stock-model props: counted, not drawn

A map's pakfile carries only the models its mapper added; a prop that names a model from the original game's archives is counted and not drawn (see [imported-maps.md](imported-maps.md#static-props)). `tools/stock_props_survey.py` ranks them from the `.bsp` files (model names are data; nothing is read from the private reference). Run on 2026-10-16: **345 stock models, 2083 placements, 1610 solid**.

**The finding that matters: 1,610 of 2,083 placements are solid.** A solid stock prop is neither drawn nor collided, so a route that depends on one (a crate to stand on, a rail, a fence) differs from the original. Most of the solid count is light fixtures and foliage, which no route uses; the rest is the list below, to be checked against routes before any Kenney stand-in is placed. Decision so far: light fixtures are `none` (not a surface anyone reads a route from), foliage is `none` unless a map's look depends on it, and boxes, fences and rails get a Kenney stand-in only where they are solid and on a route. No stand-in has been placed yet.

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

The rest are in the tool's output.
