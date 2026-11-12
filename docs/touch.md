# Touch controls

On a phone or tablet (`DotPlatform.has_touch()`), the client shows dot-mobile's overlay over the HUD: a stick planted where the left thumb lands, drag-to-look on the right half, and four drawn buttons (jump, duck, FIRE, R). On a desktop nothing shows and nothing changes.

## What a thumb does

| Button | Does | How |
| --- | --- | --- |
| JUMP | holds jump | the `BUTTON_JUMP` bit on the sampler, the same bit Space sets |
| DUCK | holds crouch | the `BUTTON_CROUCH` bit |
| R | restarts the run | the same call as the restart key |
| MENU (top right) | opens the menu | the same call as Escape |

`G2GTouch` (`game/g2g_touch.gd`) builds the overlay and declares this layout. It drives the client's own `DotFpsTouchSampler`, so a run sees a thumb exactly as it sees the keyboard: the simulation, the timer and the replays do not know the difference.

## Two samplers

Offline the player's own sampler takes the keys; online the netcode's does. Both are `DotFpsTouchSampler` on a touch device. `G2GTouch.sync()` runs every frame and hands the overlay whichever sampler is active, and dot-mobile lifts the fingers and bits on the one it leaves.

## While something else has the screen

A menu, the console, chat, the load gate or spectating pauses the overlay: it hides, lifts its fingers, and a tap meant for the menu never lands on JUMP.

## The emulated mouse

Godot turns each touch into a mouse event too. The client's input code skips touches the overlay forwarded and the emulated mouse events (`InputEvent.DEVICE_ID_EMULATION`), so a drag never turns the view twice. The first touch also counts as the "click to play" a desktop player gives.

## The server's say

The server registers dot-mobile's cvars (`sv_mobile_touch`, `sv_mobile_schemes`, `sv_mobile_sens_min`/`_max`, `sv_mobile_left_handed`, `sv_mobile_buttons`, `sv_aim_assist*`, `sv_autofire*`) and the client follows them; see dot-mobile's design doc. `sv_mobile_touch 0` hides the overlay. Aim assist and auto-fire stay inert: there is nothing to shoot in a run.

## Not verified on a phone

The layout, the gyro mapping and iOS's motion permission are tested headless only.
