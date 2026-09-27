# edgetx-blackbox-erase

An EdgeTX tool script that erases the Betaflight blackbox flash straight from the radio,
over the ExpressLRS / Crossfire link. No USB cable, no Configurator, no OSD menu,
no AUX switch to set up.

Useful when the blackbox flash is full and the OSD menu of your build has no
`FEATURES -> BLACKBOX -> ERASE FLASH` entry, or you simply do not want to plug the quad in.

## Requirements

- EdgeTX 2.10 or newer, black-and-white 128x64 screen or larger
- ExpressLRS or TBS Crossfire (CRSF) with **telemetry enabled** (ELRS: Telem Ratio not `Off`)
- Betaflight with the blackbox logging to the **onboard SPI flash** (`blackbox_device = SPIFLASH`)

Logging to an SD card is not supported: Betaflight itself does not erase SD cards over MSP.

## Install

Copy `SCRIPTS/TOOLS/bberase.lua` to `/SCRIPTS/TOOLS/` on the radio SD card.

## Use

1. Power the quad, wait for the link. Keep it disarmed.
2. On the radio: `SYS -> Tools -> BB Erase`.
3. The screen shows the arm state and flash usage, e.g. `Used 16.0 / 16.0 MB`.
4. **Long press ENTER**, then confirm `Erase ALL logs?` with **ENTER** (RTN cancels).
5. Wait for `Erased`. Do not power the quad off meanwhile.

Betaflight erases the whole chip at once, so the time does not depend on how full it is.
A 16 MB W25Q128 takes about 30-40 s; the script waits up to 300 s.

## Safety

Betaflight executes `MSP_DATAFLASH_ERASE` **without checking whether the craft is armed**.
The script therefore polls `MSP_STATUS` and only sends the erase command when the FC
reported DISARMED less than 2 seconds ago. The check is repeated right before sending.
If there is no fresh reply, nothing is sent.

## How it works

The script speaks MSP v1 tunnelled in CRSF frames, the same transport as the official
[Betaflight TX Lua scripts](https://github.com/betaflight/betaflight-tx-lua-scripts):

| CRSF frame | Direction | Used for |
|---|---|---|
| `0x7A` MSP_REQ | radio -> FC | `MSP_STATUS` (101), `MSP_DATAFLASH_SUMMARY` (70) |
| `0x7C` MSP_WRITE | radio -> FC | `MSP_DATAFLASH_ERASE` (72) |
| `0x7B` MSP_RESP | FC -> radio | replies |

- Arm state: bit 0 of the flight mode flags in `MSP_STATUS` (ARM is always the first box).
- Progress: `MSP_DATAFLASH_SUMMARY` reports the flash as not ready while the chip erase runs;
  the erase is done when it is ready again and the used size is 0.
- Unlike the `BLACKBOX ERASE` AUX mode, erasing over MSP does not make the FC beep.

## Tested

- RadioMaster Pocket, EdgeTX 2.12.2, internal ELRS module
- Betaflight 2026.6.1, HGLRCF405V2, W25Q128 16 MB flash: erase took about 32 s

## License

MIT, see [LICENSE](LICENSE).
