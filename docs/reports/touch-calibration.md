# Touch calibration on the A5/A6 machines, and the flaky slide to unlock

- Date: 2026-11-05
- Execution session: a5-nand (after `docs/reports/stikdebug-14pro.md`).
- The user reported two things: on the phone, the app's automatic slide to unlock for iOS 7 and 9 works only some of the time; and on iOS 10, touches do not line up (to open Settings the finger has to go below the icon).
- Not done: no commit or push; the iPhone 18 Pro was not touched; README is left to the decision session (its "known issues" line about the A5 touch being about 100 pixels off is now out of date; the one about the automatic slide to unlock on the phone still holds, section 4).

## 0. Conclusions

1. **iOS 10 touch: fixed.** The iPhone 5 (n41) used the iPod's sensor frame, which is the N81's frame scaled to 1136 lines and was never measured. iOS 10 put a tap aimed at panel line y on about 1.28 y - 338 (top-down pixels): the higher on the screen, the further up the tap landed (about 180 px at mid-screen), and nothing above line 264 could be reached at all. Solving for the measured slope and offset gives the frame y = -373 + 6804 v (v is the sensor's bottom-up 0..1). With it, on the Mac, taps at the centers of targets at the top, middle and bottom open them, and the keyboard rows begin within 5 to 10 px of where they are drawn. x was already right.
2. **The iPod touch 5 (n78, iOS 7 and 9) had the same error.** The old "taps land about 100 px high" (`a5-app.md` 2.1) was the middle of the same slope, not an offset. The n78 now uses the n41's frame; on 13G36 on the Mac, six taps at target centers from the top row to the dock (an alert button, FaceTime, Photos, Settings, Safari, Music) all opened the right thing.
3. **Slide to unlock on the Mac: two causes, neither in the touch model.** Tracing the multitouch model shows the same frame sequence reaching the guest in failed and successful swipes, every frame read. The causes are on the guest's side:
   - **After waking from a dark screen, iOS 9 ignores a drag for a moment, and goes dark again about 8 seconds after the wake whatever the finger does.** On the Mac the dead time is 1.5 to 2 seconds; it is CPU bound, so on the phone it is longer, and the app's single swipe 5 seconds after Home often fell into it (or after the screen went dark again).
   - **The app swiped along the "slide to unlock" line.** With the old frame, the app's y = 0.9 landed on guest line about 970, the text line itself: 3 of 7 swipes there unlocked, and every failure left the lock screen stopped partway. Other heights did better but still failed now and then, the slow guest being the common factor.
4. **On the 14 Pro the automatic slide to unlock is still unreliable, and the bar was not met.** A multitouch trace on the phone shows the guest's driver reading every frame of every swipe; the lock screen is what fails to keep up. It trailed the finger by 2.5 to 10 seconds, ignored nearly every swipe in the first 30 seconds after it came up (on 7.1.2 it did not even draw its clock for two minutes), and went dark 7 to 10 seconds after the last Home press, leaving a swipe still being played out stuck halfway. Of the versions tried, the kept one reached the home screen on 9.3.5 after 3 swipes in one run and 5 in the next; a third variant of it never got there, and 7.1.2 did not unlock in 12 swipes (section 4).
5. **App change (kept):** for iOS 7 to 9 each try presses Home, presses Home again 5 seconds later (which keeps the lock screen lit), and a second after that swipes across the lower middle (y = 0.7) over 1 second, keeping the finger at the end for another second before lifting; tries are 12 seconds apart. On the Mac the held swipe unlocks as before.
6. **iOS 10 touch on the 14 Pro: confirmed.** Under autodrive the app tapped the Settings icon once (0.619, 0.735) and Settings opened.
7. **By hand on the phone, iOS 7 and 9 looked dead because the app never showed the guest's screen going off.** The user found that no swipe did anything and the Power button did not lock. In their 7.1.2 session the guest turned its screen off about 10 seconds after the lock screen came up, but the app kept showing the last lit frame, so every later swipe went to a screen that was off, and Power woke it and put it back to sleep with nothing visible changing. The app now shows the screen dark while the guest's panel is off and drops touches that begin on it, as upstream's Mac app does; in the simulator, 7.1.2 goes dark by itself on the lock screen, Home and Power wake it, Power locks it, and a swipe by hand on the lit lock screen unlocks it (section 4.5). Installed on the 14 Pro, not yet tried there.

## 1. iOS 10 (n41) calibration

The sensor reports positions in its own frame, and the machine maps the panel onto it with `MTSensorProfile` (`frame_x0`, `frame_width`, `frame_y0`, `frame_height`; reported y = `frame_y0` + v `frame_height`, v bottom-up). iOS turns the sensor position into screen points with the calibration in the device's multitouch properties, so a frame that does not match what the firmware expects shows up as a linear error on screen.

Method (Mac, 14G61, `work/a5/build`): open Notes, bring up the keyboard, and press and hold at x = 240 for aims y = 715 to 1130 in 5 to 10 px steps; each hold shows the key popup, so the row hit for each aim can be read off the screen. The row boundaries against the aims fit a line with slope 1.28; in bottom-up pixels, `Y_land = 1.28 Y_aim + 19.9`. For a frame (y0, H) the correction is `H' = H / a`, `y0' = y0 - b' H / (a * 1136)`, which turns (-254, 8709) into (-373, 6804).

Check with the new frame: taps aimed at the centers of home screen icons in the top row, the middle and the dock, and of Notes' buttons, open them; the keyboard scan puts the top row's start at aim 720 and the second row's at 820, within 5 to 10 px of the drawn rows. A scan along x on the keyboard puts each key's center where it is drawn (for example x 248 to 328, center 288, for a key drawn there).

## 2. iOS 7 and 9 (n78) calibration

The same frame was put on the n78 and checked on 13G36 (`work/a6/regress/disk-935.img`, snapshot mode) by tapping the center of each target, 120 to 150 ms per tap:

| Target | Aim (x, y) | Result |
|---|---|---|
| "Don't Trust" in the "Trust This Computer?" alert | 456, 685 | Alert dismissed |
| FaceTime (top row) | 91, 112 | FaceTime |
| Photos (top row) | 395, 112 | Photos |
| Settings (fourth row) | 243, 817 | Settings |
| Safari (dock) | 243, 1031 | Safari |
| Music (dock) | 547, 1031 | Music |

The frame change is linear, so if the new frame is right, the old one put a tap aimed at y on 1.28 y - c here as well; that matches the old observation that aiming 100 px below the Settings icon was needed to open it.

`scripts/ios/sim-settings.sh` in the simulator (rebuilt simulator QEMU and app, iPhone 18 Pro simulator), passing the icon centers with no compensation:

| System | Settings icon | Lock screen | Home screen | Settings | Notes |
|---|---|---:|---:|---:|---|
| 9.3.5 (n78ap-13G36) | 0.380, 0.719 | 79 s | 89 s | 103 s | One unlock swipe, one tap |
| 7.1.2 (n78ap-11D257) | 0.128, 0.735 | 40 s | 68 s | 121 s | Second unlock try; Settings exited once by itself (below) |
| 10.3.4 (n41ap-14G61) | 0.619, 0.722 | 86 s | 110 s | 132 s | Home only (second press), one tap |

On 7.1.2 the first tap (76 s) opened Settings: from 78 s the guest showed its window with no rows, and the frame serial in `stats.csv` did not move from 78 to 98 s, so the script's second tap (92 s) landed on that empty window. At 99 s the guest was on the home screen again: Settings had closed by itself, about 20 seconds after its window appeared, which is the length of iOS's launch watchdog; that cause is a guess, since the run keeps only the kernel console (`serial-0.log`), which has nothing about it. At 100 s the empty window was back (13 new frames, before any further tap), the third tap (106 s) landed on it, and the rows were drawn by 121 s. Every tap was on the Settings icon or on Settings' own window; the delay is Settings starting on the slow guest, not the touch.

Run directories: `work/ios/runs/20261105-011226-n78ap-13G36-jit`, `20261105-011417-n78ap-11D257-jit` and `20261105-011626-n41ap-14G61-jit`; logs `work/ios/runs/sim-settings-cal-*.log`.

## 3. Slide to unlock

### 3.1 The touch frames are fine

The model's trace event (`ipod_touch_multitouch_log`, switched on at run time with HMP `trace-event ipod_touch_multitouch_log on` and `log trace:ipod_touch_multitouch_log`) was compared for failed and successful swipes on 13G36: the same TOUCH_START, about 45 TOUCH_MOVED frames 17 ms apart, TOUCH_ENDED and FULL_END 100 ms later, frame numbers without gaps, and every frame read by the driver right after the ATN pulse. The driver's controller init after a wake (firmware download, report setup) is done within 0.2 seconds of the Home press, before any of the swipes below.

### 3.2 Dead time after waking, and the 8 second screen

On the Mac (13G36), each trial: hold button (screen off), 3 seconds, Home (wake), wait, swipe across y = 600 over 600 ms, screenshot 3 seconds later.

| Wait after Home | Unlocked |
|---|---|
| 0.5 s | 1 of 4 |
| 1 s | 15 of 22 (four series) |
| 1.5 s | 2 of 3 |
| 2 s | 3 of 3 |
| 2.5 s | 3 of 3 |
| 3 s | 4 of 4 |
| Home pressed again on the lit screen, then 0.5 s | 3 of 3 |

In a failed early swipe, a screenshot while the finger is still down shows the lock screen not moving at all: the touch is ignored, not snapped back. Pressing Home on a lit lock screen does not bring the dead time back. Holding the finger down from 0.5 s and moving it only at 3.5 s worked 2 of 3 times, so starting early does not help.

After a Home wake, the panel turned off (`ApplePinotLCD::_lcdEnable: enable: 0`) 7.7 and 8.8 seconds later with no touch, 9.2 seconds later with drags at 3 and 6 seconds, and 7.8 seconds later with drags at 0.3 and 0.8 seconds. Touches on the lock screen do not keep it lit.

The guest's timers run on the virtual clock, which follows wall time, while the dead time is CPU bound. On the phone the window between the two is narrow or gone. In the 7.1.2 run `work/ios/runs/device14/20261104-211336-n78ap-11D257-jit`, the lock screen was still fading its clock in about 20 seconds after it was first recognized; four tries (Home, swipe 5 seconds later) did nothing, the screen went dark once, and the fifth worked.

### 3.3 Where the swipe goes

The app swiped from (0.18, 0.9) to (0.92, 0.9). With the old frame, y = 0.9 (line 1022) landed on guest line about 970, which is the "slide to unlock" text. Swipes 2 to 5 seconds after a wake (x 80 or 115 to 580 or 589, 600 ms) gave:

| Frame | Aim y | Guest y | Unlocked |
|---|---|---|---|
| old | 600 | about 430 | 10 of 10 (2 to 3 s after the wake) |
| old | 700 | about 560 | 2 of 2 |
| old | 900 | about 814 | 3 of 3 |
| old | 1022 | about 970 | 1 of 3, and 2 of 4 with the app's 5 s wait |
| new | 795 | 795 | 7 of 7 (2.5 s), then 4 of 9 in two later series (3 s) |
| new | 930 | 930 | 4 of 4 |
| new | 1022 | 1022 | 6 of 8 |

(The first unlock after each boot is left out: it takes longer than the 3 second screenshot, at any height.)

All four failures at line 970 left the lock screen shifted partway with the finger already up. One of them stayed that way, lit, for over 40 seconds until the next touch; on the phone that looks the same as a swipe that did nothing. The text line is the worst place, but not the only one: in the later series at line 795 (after many lock and wake cycles in the same boot) two swipes were ignored outright and three left a partial state, one of which went on to unlock by itself within a minute. The slow guest is the common factor, which is why the app now retries within each wake rather than relying on one well placed swipe.

### 3.4 The app change

`app/ClassicTouch/EmulatorViewController.swift`, `unlock`, as kept after the phone runs in section 4 (the first version of this round, with three quick swipes per wake, did worse on the phone):

- iOS 10 and later: Home only, as before.
- iOS 7 to 9: Home; Home again 5 seconds later, on the lit lock screen, which restarts its timer so that it does not go dark during the swipe; 1 second after that, a swipe across y = 0.7 (their whole lock screen follows the finger), away from the text line and below where notifications are listed, from x 0.18 to 0.92 over 1 second, with the finger kept at the end for another second before it lifts. Logged as `unlock_swipe` in events.log. The same for the `unlock` control file, `-autounlock` and autodrive; autodrive repeats it every 12 seconds as before.
- iPhone OS 1 to 6: unchanged (Home, then one 600 ms swipe at y = 0.9, where their slider is, 5 seconds later).
- `Engine.drag` takes `holdMilliseconds`: the finger stays at the end point (an update every 100 ms) before the end event.

On the Mac (13G36), a swipe held still for 1 second at the end before lifting unlocks like a moving release: 3 of 3 after the first unlock of the boot, and 3 of 3 for a 1 second swipe without the hold. In the simulator, `scripts/ios/sim-settings.sh` with the kept version unlocked on its first swipe and opened Settings on both: 9.3.5 lock screen 74 s, swipe 82 s, home screen 86 s, Settings 97 s; 7.1.2 at 36, 43, 47 and 66 s (runs 20261105-035321 and 20261105-035506). The swipe test (`-swipetest`) still swipes at y = 0.9 so that its numbers stay comparable with earlier runs.

## 4. On the iPhone 14 Pro

All runs: `PHONE=… STIK=1 FILES=devicectl scripts/ios/device-boot.sh <device> jit <limit>` (JIT from StikDebug on the phone, the app's autodrive recognizes the screens and unlocks), iOS 27.0.1, 2026-11-05, run directories under `work/ios/runs/device/`. After the third run below the decision session capped the phone at five more runs; the bar for calling the slide fixed was 9.3.5 reaching the home screen within three swipes in two runs in a row. **It was not met.**

### 4.1 What a trace on the phone shows

QEMU for iOS is built with the nop trace backend, so `-d trace:…` does nothing there. For these runs the iOS work tree's `hw/arm/ipod_touch_multitouch.c` had a temporary change: with `IT_MT_TRACE=1` in QEMU's environment (`QEMUENV`), the model's trace lines went to stderr, which the app writes to the run's `qemu.log`. It is not in `patches/`; the tree was restored and the phone's app rebuilt and reinstalled without it.

- **The guest reads every frame.** Each swipe of the kept version is about 100 frames (TOUCH_START, the moves, TOUCH_ENDED, FULL_END), and the driver read every one of them right away whenever the touch controller was powered. Touch reaches the guest kernel as on the Mac.
- **The lock screen does not keep up.** In guest screenshots taken every second, a swipe that worked began to move the lock screen 2.5 seconds after the finger went down and finished 3 seconds after it lifted (031535); in 032002 the unlock animation took about 10 seconds. Most swipes did not move the lock screen at all, even with every frame read and the screen lit, and no boot unlocked on its first two tries.
- **The screen goes dark 7 to 10 seconds after the last Home press** (the driver powers the touch controller down with report 0x7e). A swipe still being played out then is left stuck: in 025706 a swipe 7.9 seconds after Home left the lock screen halfway across, it stayed like that for 30 seconds, and two Home presses in that time did not bring the touch controller back (its firmware was loaded again only 22 seconds after the first). A Home press on the lit lock screen restarts the timer: in 031535, with a second Home press 5 seconds into every try and tries 12 seconds apart, the screen never went dark. With tries 14 seconds apart (032002) the next Home press came just as the screen went dark, and twice a swipe began while the touch controller was still off, so only part of it reached the guest (92 and 45 of about 100 frames).
- **7.1.2 is slower still.** In 033611 its lock screen drew no clock until about 160 seconds (two minutes after it was recognized), and no swipe moved it.
- In the first run of the round (024039), the app's second swipe of each wake (5 seconds after Home, only if the lock screen had been recognized in an image taken after the first swipe ended) never fired, so only the 2.5 and 7.5 second swipes ran.

### 4.2 Runs

9.3.5 (13G36). "Tries" counts Home presses by autodrive (one per try), "swipes" the swipes made.

| Run | App's unlock | Lock screen | Tries / swipes | Home screen |
|---|---|---|---|---|
| 20261104-231623 (`stikdebug-14pro.md`, before this round) | Home, one 600 ms swipe at the text line 5 s later, every 12 s | 80 s | 8 / 8 | 172 s |
| 024039 | first version of this round: y = 0.7, swipes 2.5, 5 and 7.5 s after Home | 93 s | 12 / 24 | not within 600 s |
| 025706 (trace) | same | 101 s | 4 / 5 | 144 s |
| 030839 (trace) | one swipe 3 s after Home, 1 s with 1 s held | 95 s | 7 / 7 | 180 s |
| 031535 (trace; run 1 of the five) | **kept version**: Home, Home 5 s later, swipe at 6 s (1 s, 1 s held), every 12 s | 84 s | 4 / 3 | 123 s |
| 032002 (trace; run 2) | same, but the first try 20 s after the lock screen and tries every 14 s | 80 s | 6 / 5 | 178 s |
| 032611 (trace; run 3) | same as 031535, but the first two tries only press Home (the first swipe about 30 s after the lock screen) | 81 s | 12 / 10 | not within 420 s |

The kept version is 031535's: it had the best result and keeps the screen lit. 032611 differs from it only in pressing Home without swiping in its first two tries, and none of its ten swipes worked, so with this few runs the difference between the variants may be chance more than design.

7.1.2 (11D257) with the kept version (033611, run 4): lock screen at 41 s, 12 tries and 12 swipes, home screen not reached within 600 s (as in `stikdebug-14pro.md`, where it also stayed on its lock screen).

10.3.4 (14G61) with the kept version (034851, run 5): lock screen at 102 s, the Home press at 103 s opened the home screen at 104 s. Autodrive then found the "Settings" label at (0.619, 0.795), tapped the icon above it at (0.619, 0.735) once, the Settings page was recognized 9 seconds later, and Home brought the home screen back. **The iOS 10 touch fix holds on the phone**: one tap at the icon's center opened it.

### 4.3 Where this leaves the slide on the phone

The automatic slide to unlock for iOS 7 and 9 on the phone is still a known issue: 9.3.5 got there in 3 to 10 or more swipes per boot, 7.1.2 not at all. It is not the touch path (every frame reaches the guest's driver, and the same swipes unlock at once in the simulator and on the Mac) but the pace of the guest's lock screen on the phone, which lags seconds behind and ignores touches for long and irregular stretches. The app's process runs at 115 to 120% CPU (`stats.csv`) throughout the lock screen. Possible next steps, none done here:

- Find where the guest's time goes on the phone while the lock screen is up (`PERF=1` logs the GL bridge, display and frame publishing times every second), since the same build is fast enough in the simulator.
- Try unlocking by hand on the phone: a person sees the lock screen move and can hold or retry, which the app cannot. The user did, after these runs, and found the app hiding that the screen had gone off (section 4.5); with that fixed it has yet to be tried.
- The two-Home-presses-per-try pattern relies on Home being harmless on a lit lock screen, which holds on iOS 7 to 9 without a passcode.

### 4.5 By hand on the phone: the screen went off and the app did not show it

After the runs above, the user tried by hand on the 14 Pro: on iOS 7 and 9 no swipe did anything and the Power button did not lock the screen, while iOS 10 behaved normally. Their 7.1.2 session (`20261105-045337-n78ap-11D257-jit`, copied from the phone) lasted 71 seconds before the app went to the background. Its serial log has SpringBoard's "Disabling lock screen media controls updates for screen turning off" and `AppleARMBacklight::setBacklightEnableGated 0` at guest time 0:49, about 51 seconds into the app, some 10 seconds after the lock screen came up (41 s in 033611). The guest had turned its screen off, as a real one does on an untouched lock screen, but the app kept showing the last lit frame: every swipe after that went to a screen that was off (its touch controller powered down), and Power woke the guest and put it back to sleep with no visible change.

The bridge already says whether the guest's panel is off (`qemu_ios_ui_display_sleeping`: the last DCS display-off or sleep-in command for DSI panels, which include the n78 and n41, or the LCD brightness on the older iPods), and `Engine.displaySleeping` wrapped it, but nothing read it. Upstream's Mac app dims the screen and takes no input while it is set. (`stats.csv`'s backlight column is -1 on these machines; it reads another hook.)

**App change:** `EmulatorViewController.tick()` reads it on every display refresh. While the guest's screen is off, the app's screen shows dark (the layer's contents are cleared, leaving the view's near-black background), and a touch that begins on it is not sent, through to its end; on wake the last frame is shown again until the guest draws. `display_sleep` and `display_wake` go into events.log.

Check in the simulator (iPhone 18 Pro, 7.1.2, `20261105-170125-n78ap-11D257-jit`, no autodrive, the app's buttons and touches driven through the simulator):

- On the lock screen the guest went to sleep by itself at 66.9 s (`display_sleep`) and the screen went dark.
- Home woke it (`display_wake` at 79.2 s), and it went dark again 9.3 s later with nothing touched.
- A quick swipe (0.6 s) about 5 s after that first wake did not move the lock screen. After the next wake, a drag across y = 0.74 at about 0.85 s with the finger held 0.6 s at the end, begun 2 s or more after the wake, unlocked to the home screen.
- On the home screen, Power put the guest to sleep (`display_sleep` at 195.1 s, dark), and Power again woke it to the lock screen (`display_wake` at 206.3 s).

9.3.5 (`20261105-170511-n78ap-13G36-jit`): the guest went to sleep by itself on the lock screen at 78.0 s, and the `home` control file woke it at 79.2 s. 10.3.4 (`20261105-170636-n41ap-14G61-jit`): its lock screen never went off by itself in 300 seconds (the clock kept ticking over each minute, and the serial log has no backlight-off line), which is why iOS 10 seemed fine by hand. In a second boot (`20261105-171231-n41ap-14G61-jit`), Power on its lock screen put it to sleep (`display_sleep` at 93.5 s, dark) and Home woke it (`display_wake` at 104.1 s), so the n41 reports its panel the same way.

What this does not change: on the phone the lock screen is as slow as in section 4.1, so by hand a person still has to press Home when the screen goes dark and may need a few slow swipes in the first half minute or so; that has not been tried on the phone with this build yet.

### 4.4 Test tooling added

- `scripts/ios/device-boot.sh`: `GUESTPNG` (seconds between guest screenshots in STIK mode, 5 by default; 1 was used here) and `QEMUARGS` (extra QEMU arguments in STIK mode).
- The app reads `qemuargs` from `autostart.json` as well as from `-qemuargs` (StikDebug launches the app without arguments).

## 5. The app's name (same round, asked by the decision session)

The project is now called Slide to Unlock, and the app's user-facing name follows. The bundle ID `org.classictouch.app`, the target and product name `ClassicTouch`, the file names and the patch codenames stay, so devices already imported on phones are kept.

- Home screen name (`CFBundleDisplayName` in `app/project.yml` and `app/ClassicTouch/Info.plist`): "Unlock"; the full name would be cut short under the icon.
- The header on the timeline page (`LibraryCells.swift`) and the title on the About page (`SettingsViewController.swift`): "Slide to Unlock".
- `Localizable.xcstrings`: "About Slide to Unlock", "Slide to Unlock is free software, …" and "Slide to Unlock is an open-source project …"; the zh-Hans translations keep the name untranslated ("关于 Slide to Unlock").
- The About page's source link: `https://github.com/kurisu12h/slide-to-unlock`.
- `ThirdPartyLicenses.txt`: its first and seventh lines.

Checked in the simulator (iPhone 18 Pro, iOS 27.2) in English and in Simplified Chinese: the home screen shows "Unlock" under the icon; the timeline page header, the Settings row "About Slide to Unlock" / "关于 Slide to Unlock", the coffee card, the About page title and license paragraph, and the first lines of the library licenses all show the new name.

## 6. Files

- `patches/a5-n78-skeleton.patch` (regenerated): `hw/arm/ipod_touch_5g.c`, the n41 and n78 sensor frames and their comments.
- `app/ClassicTouch/EmulatorViewController.swift`: `unlock` (section 3.4); `qemuargs` read from `autostart.json` too; the dark screen while the guest's panel is off, touches dropped on it, `display_sleep`/`display_wake` (section 4.5).
- `app/ClassicTouch/Engine.swift`: `drag` takes `holdMilliseconds`.
- `scripts/ios/device-boot.sh`: `GUESTPNG` and `QEMUARGS`.
- `app/project.yml`, `app/ClassicTouch/Info.plist`, `LibraryCells.swift`, `SettingsViewController.swift`, `Localizable.xcstrings`, `ThirdPartyLicenses.txt`: the name.
- `scripts/ios/sim-settings.sh`: the usage comment and the `TRUST_TAP` default now take the centers of what is tapped (Settings icon 0.380,0.719 on 9.3.5, 0.128,0.735 on 7.1.2, 0.619,0.722 on 10.3.4; "Don't Trust" 0.713,0.603) instead of points moved 100 px down.
- `tools/a5/README.md`: the two notes that taps land about 100 px high are replaced, and the recipes' taps and swipes use uncompensated points (7.1.2: swipe at y=795, Settings at 82,835; 9.3.5: swipe at y=795, "Don't Trust" at 456,685, Settings at 243,817; 10.3.4: Settings at 396,820; the `sim-settings.sh` example).
- This report.
