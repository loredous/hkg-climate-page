# Gen5W head unit: climate, seat and steering-wheel commands (2023 US Ioniq 5)

What the [hkg-climate-page](https://github.com/loredous/hkg-climate-page) project has positively
identified about commanding the climate controls from the head unit, by logging the stock
controls on a real car. Shared so others don't have to start from scratch.

**Read this first**

- **One car, one firmware.** Everything here was confirmed on a 2023 US Hyundai Ioniq 5, head
  unit product `NEEV23.USA.0000.V015.012.260507` (D-Audio Plus, Android 4.4.2). Other models,
  regions or firmware may use different transaction codes or values. Check on your own car
  before relying on anything here.
- **No range checks.** The stock services pass values straight to the car's controllers with no
  validation. Send only the values listed here; they are the ones the stock controls were seen
  sending. Don't send a value or flag you haven't seen the stock controls send on your car.
- **Errors are hidden.** `USMManager`'s setters catch their own `RemoteException` and only log it,
  so a refused command looks like success. Always confirm a command through its read-back.
- Transaction codes are for the firmware above. On another build the same number can be a
  different method, including a setter, so a "read" by number could send a command. Check the
  `IxxxService$Stub` codes of your own `automotive.odex` first.

**How it was found.** We recorded the Android log (`logcat -v threadtime`) while pressing each
stock control a few seconds apart, then matched the UI log lines to the service calls, the MICOM
frames (`micomd`) and the car's status replies. Method names and codes come from the stock
`automotive.jar` interfaces and the services in `automotive-service.jar`. No vehicle command was
sent by us during discovery.

## Reaching the services

- Apps link the stock `automotive` library (`<uses-library android:name="automotive"
  android:required="false" />`) and get managers through
  `com.hkmc.VehicleInfoManager.getInstance(context).getService(...)`.
- `DATCManager` (climate): binder `com.hkmc.micom.datc`, interface `com.hkmc.datc.IDATCService`.
- `USMManager` (seats, steering wheel, eco): binder `com.hkmc.micom.usm`, interface
  `com.hkmc.usm.IUSMService`.
- `BCMManager` (body): binder `com.hkmc.micom.bcm`.
- An ordinary app uid could call the USM seat setters and read DATC and BCM on this car (tested).
  Calling the DATC setters from an ordinary uid is not tested yet; the stock code shows no uid or
  permission check on them. The stock climate app runs as `android.uid.phone`.

## Front seat heating and ventilation (confirmed)

| | |
|---|---|
| Set | `USMManager.setFrontSeatHeatDrvStep(int)` (usm 0xd5), `setFrontSeatHeatAstStep(int)` (usm 0xd6) |
| Values | 2 off; 8 / 7 / 6 heat high / mid / low; 5 / 4 / 3 ventilation high / mid / low |
| MICOM | `ff 92 11 01 11 28 00 03 00 <seat> <value> ..` (`USM_Front_Seat_Heat_SET_C_REQ` 0x1128; seat 0 driver, 1 passenger) |
| Read-back | `USM_Front_Seat_Heat_SET_M_RESP` (0x9128) within ~40 ms; `BCMManager.getDrvSeatHeatState()` / `getAstSeatHeatState()` (bcm 21 / 23); `USMManager.getFrontSeatHeat_DrvState()` / `_AstState()` (usm 583 / 584); listener `IBCMListener.onDrvSeatHeaterStatusChanged(int)` |
| Option | `FrontSeatHeat_DrvOption` / `AstOption` read 6 on this heat-and-ventilation car (guess: 6 = heat and ventilation fitted) |

First found by eclipseempire's MIT-licensed `hkmc-coldstart-heat`. The stock climate app
(`SeatHeatVentPopup` -> `ClimateManager`) sends exactly these.

## Steering-wheel heat (confirmed)

| | |
|---|---|
| Set | `USMManager.setSWRC_SteeringwheelWarmerSet(int)` (usm 0xd4) |
| Values | **a toggle**: the stock button sends 1 on touch-down and 0 on touch-up; each press switches heat on or off. On/off only on this car (no levels). |
| MICOM | `USM_SWRC_SET_C_REQ` (0x1127): `ff 92 11 01 11 27 00 03 00 01 49`, then `.. 00 00 48` |
| Read-back | `getSWRC_SteeringwheelHeatIndStep2()` (usm 0x244): 1 on, 0 off; also `getSWRC_SteeringwheelHeatingOpt()` 0x241, `...SWInf()` 0x242, `...IndStep1()` 0x243; listener `onSWRCStatusReceived(opt, swInf, step1, step2)` |

To set a state, read step 2 first and press only if it differs. (An older route through the voice
service, `com.hkmc.micom.vr` `C_StrgWhlHeatedCmdAVN`, exists in the code but isn't what the stock
climate screen uses.)

## Climate eco mode (confirmed)

| | |
|---|---|
| Set | `USMManager.setClimateControlECOMode(int)` (usm 0xc2); sent from Vehicle Settings |
| Values | 2 on, 1 off on this car. The stock code swaps them on cars whose CAN-DB generation is 1 or lower; this car reports generation 2 (`getCanDbGeneration can::2` in the log). |
| MICOM | `USM_Seat_ETC_C_REQ` (0x1122): `ff 92 11 01 11 22 00 03 01 <value>` |
| Read-back | `getClimateControlECOMode()` (usm 0x229): 1 on, 0 off, about 60 ms later |

## Cabin climate (confirmed)

All of these go through one call: `DATCManager.setFrontClimateControl(int flag, int value)`
(datc transaction 0x41). The service logs
`D/DATCService: setFrontClimateControl ---> flag: <flag>, set1: <value>` and then
`[DATC] success::HU_DATC_<name>(<value>)`, and sends a MICOM frame
`ff c2 43 00 43 <function id> 00 02 <value>`. The car's climate controller answered every command
with new state within 20-70 ms, so the head-unit screen is a real control on this car, not only a
display.

| Item | Flag | Function | Values the stock screen sent |
|---|---|---|---|
| Driver temperature, one step | 50 (0x32) | `DrTempUpDn` 0x30 | 1 up, 2 down |
| Passenger temperature, one step | 49 (0x31) | `PsTempUpDn` 0x2f | 1 up, 2 down |
| Fan speed, one step | 4 | `MainBlowerUpDn` 0x2e | 1 up, 2 down |
| Climate off ("fan off" button) | 51 (0x33) | `MainBlower` 0x13, sent as 0 | 1 |
| Auto | 8 | `AutoSet` 0x15 | 1 |
| A/C | 9 | `AcSet` 0x16 | 0 off, 1 on |
| Airflow | 6 | `FrontModeSet` 0x14 | 1 face, 2 face and floor, 3 floor, 4 floor and defrost |
| Sync | 22 (0x16) | `SyncSet` 0x29 | 2 when turning it on, 1 when turning it off |
| Driver only | 24 (0x18) | `DrvOnlySet` 0x2a | 1 (turning it off was done with Sync) |
| HEAT button | 48 (0x30) | `HeatSet` 0x2b | 1 on, 0 off (what it does is unclear) |

Behaviour seen on the car:

- **Temperature** steps by 1 °F or 0.5 °C. The screen never sent an absolute temperature.
- **Fan** has 8 speeds (raw 2..9). Presses at either end are acknowledged with no change. From
  auto (raw 1) a press went to raw 2.
- **"Fan off" turns the whole climate off** (operating state 2, temperatures blank). Pressing it
  again sends nothing.
- **Any climate command wakes the climate** when it is off: in one capture a driver-only press
  turned it back on in auto with A/C.
- **Auto** presses cycle the auto intensity (3 steps). There is no "auto off" command; A/C off
  (and manual changes) leave auto.
- **Sync** on also turns driver-only off. While driver-only is on, the passenger temperature
  reads 0.
- **Airflow:** the stock popup offered 4 modes on this car (`modeCount` 4). Mode 0 means auto
  and is only ever reported, never sent. There is no per-side airflow command.

### Reading the cabin state

- `DATCListener.onDatcStatus(...)` reports every change. It is easier to poll
  `getVRClimateStatus(int flag)` (datc 0x29, returns a float), which reads the service's cached
  values:

  | Flag | Meaning |
  |---|---|
  | 2 | driver temperature (display unit) |
  | 5 | fan raw level (0 off, 1 auto, 2..9 speeds 1..8) |
  | 6 | airflow mode |
  | 8 | auto (1 on) |
  | 9 | A/C (1 on) |
  | 11 | intake: 1 recirculation, 2 fresh air |
  | 12 | operating state: 1 on, 2 off |
  | 13 | temperature unit |
  | 22 | sync |
  | 29 / 31 | passenger temperature raw byte (°C / °F) |

  Flags 24, 28, 30 and 212 returned -1 on this car even when valid; use `getDriverOnlyValue()`
  (datc 0x27) for driver-only.
- **Raw temperature byte:** °F = byte + 56; °C = byte / 2 + 14. For example 71 °F is 15. The
  stock range on this EV is 62-82 °F / 17-27 °C.
- **Unit:** `getTemperatureUnit()` (datc 3): 1 °C, 2 °F.
- `supportFrontClimateControl()` (datc 0x40) returned true.

### Outside temperature

There is no getter. `DATCManager.addTemperatureListener(DATCTemperatureListener)` sends a snapshot
as soon as the listener is registered, then updates. In `onAllTemperatureChanged` (17
arguments), parameters 9-12 are outside °C, its state, °F, and its state. The reading is valid
only if the state is `0xffff` (`0xff` invalid, `0xfe` sensor error, `0` off), the value isn't
`100000.0`, and it isn't -40. `onOuterTempChanged(float, int unit)` uses unit 0 °C, 1 °F.

## Voice

The offline recognizer accepted "**air conditioner on**" (intent `ACOn`, command 301120). With the
climate off, it sent auto on and then an absolute driver temperature of 64 °F through
`DATCManager.setVRClimateStatus(flag, set1, set2)`, which reaches the same frames (`AutoSet` 1,
`DrTempSetF` byte 8). Phrases about seat heating or cooling, and plain "turn on" or "turn off",
were rejected.

## Not available from the head unit on this car

- **Front defrost, rear defrost, recirculation:** the stock climate screen has no control for
  them, and no voice phrase reached them so far. The service code has a front-defog flag (10)
  and an intake flag (11), and the voice service has a rear-defogger command, but no stock
  control was seen sending them, so their values are unconfirmed. Their state can be read:
  intake (flag 11 above), and the car's status nodes `Windshield.Front.Defog.State`,
  `Windshield.Rear.Defog.State` and `C_DefoggerRly`.
- **Mirror heat:** there is no separate mirror heater signal on this car. The mirrors share the
  rear defroster relay.
- **Rear seat heating:** `RearSeatHeat` options read 0 (not fitted on this car).
- **MAX A/C:** only a display string, with no command.

## Never send

These are housekeeping, not controls:

- DATC flag 32 (`DisScrnSet`), which tells the controller which screen is shown.
- `HU_VRActivity` (function 0x01), which marks voice sessions.
- The boot-time `ff 92 11 .. fa fa` frames, which are queries; `0xfa` is not a value.

## Bonus: the right-hand split screen

- The right panel is `com.mobis.splitscreen.right` (`/system/app/RightScreenHome.apk`), a
  640 x 720 px window. Its pages are hard-coded in the app. `SplitScreenManager` lists fixed ids:
  AV 2, MAP 3, CLIMATE 4, CLOCK 10, and so on.
- The owner's page list is `Settings.System` `ss_setting` (per profile `ss_setting_dr1` /
  `_dr2`), a comma-separated id list. Climate (4) isn't offered on this car's firmware, and no
  other app can register a page.

## Credits

eclipseempire's [hkmc-coldstart-heat](https://github.com/eclipseempire/hkmc-coldstart-heat) (MIT)
for the seat-heat path, and the NEMESIS project for the tooling that made logging on the car
possible.
