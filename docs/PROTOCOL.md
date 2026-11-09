# GD-88 / PeriPage A40 protocol notes

What gd88bridge relies on. The facts come from three places:
- measurements on an HZTZ GD-88 (firmware V6.0.4, hardware 1.08)
- the bytes produced by the vendor's macOS driver (`rastertoGD88`)
- the reverse-engineered [PeriPage V1.22 protocol document](https://github.com/aaa4xu/peripage), which
  covers the A6 model; anything taken only from it is marked *(A6 doc)*

None of this comes from an official specification, because there isn't one.

## Transport

- **Classic Bluetooth.** The printer offers the Serial Port Profile on RFCOMM channel 1 (MTU 127).
  gd88bridge uses this through IOBluetooth and gets about 33 KB/s. RFCOMM's own flow control paces
  the data.
- **Bluetooth Low Energy.** The printer also advertises BLE, which the iOS app uses. gd88bridge doesn't
  use it.
- **One connection at a time.** The printer's light turns blue while a device is connected.
- **Wait between connections.** Keep **at least 2 s between disconnecting and reconnecting**, otherwise
  the printer drops the new channel.
- **Don't use `/dev/cu.GD-88_XXXX`.** macOS creates this serial port for the printer, but writing to it
  printed once and then left `tcdrain()`/`close()` blocked in the kernel. The only fix was turning
  Bluetooth off and on.
- **Don't use CUPS's built-in `bluetooth` backend.** It never found the printer.

## Print job

This is what the vendor driver sends with media type "Continuous" (the default); gd88bridge sends the
same bytes:

```
10 FF F1 02  10 40  1F 80 01 10  10 FF 10 00 00       job start (the last 5 bytes set darkness 0)
1D 76 30 00 D2 00 18 00 + 24 x 210 bytes              GS v 0 raster strip: 1680 dots, 24 rows, 1 = black
...                                                   more strips; pages follow each other directly
1B 4A 60  10 FF F1 45                                 feed 96 dots (12 mm), end of job
```

- Each page is padded with white rows to a multiple of 24.
- The vendor driver's Darkness option (0–2) doesn't change the bytes: it always sends darkness 0.
- The media types "Label" and "Folded with marks" add `1F 11 51` after the start bytes and send
  `1D 0C 1F 11 50` before the end bytes (page-mark search).
- The printer answers the end-of-job command with **`AA`** once it has received the whole job.

## Read-only queries

| Command | Reply |
|---|---|
| `10 FF 20 F0` | model, e.g. `PeriPage_A40` |
| `10 FF 20 F1` | firmware, e.g. `V6.0.4` |
| `10 FF 20 F2` | serial number (ASCII) |
| `10 FF 30 10` | hardware version, e.g. `1.08` |
| `10 FF 30 11` | Bluetooth name, e.g. `GD-88_XXXX` |
| `10 FF 30 12` | classic and BLE addresses (12 raw bytes) |
| `10 FF 11` | `00 00 00`: darkness, speed, paper flag (the A6 returns 4 bytes) |
| `10 FF 50 F1` | battery %, 16-bit big-endian. It's estimated from voltage *(A6 doc)*, so it varies by about ±3 % and rises while charging. |
| `10 FF 40` | status byte, see below |

Standard ESC/POS status commands (`DLE EOT`, `GS r`, `GS I`), `1F 11 xx` and `10 FF C0 00` get no reply.

## Status byte (`10 FF 40`)

| Bit | Meaning | Source |
|---|---|---|
| `0x02` | lid open; the paper bit is set as well while it's open | measured |
| `0x04` | no paper | measured |
| `0x08` | low battery | *(A6 doc)* |
| `0x10` | print head too hot: set above 70 °C, cleared below 65 °C | *(A6 doc)* |
| `0x01` | print or calibration error | *(A6 doc)* |

`00` means ready.

## Events the printer pushes

While connected, the printer sends 2-byte events on its own:

| Event | Meaning |
|---|---|
| `FF 02` | lid opened |
| `FF 05` | lid closed |
| `FF 01` | no paper; sent when the lid closes without paper |

gd88bridge only treats these as a cue to read the status byte again; the status byte is the source of truth.

## Never send these

They're listed in the PeriPage documents. gd88bridge doesn't use any of them:

| Command | What it does |
|---|---|
| `10 FF E0 AA AA`, `10 FF EE AA AA` | maintenance mode: writes flash memory and resets the printer *(A6 doc)* |
| `10 FF 20 F4 …` | writes the serial number |
| `10 FF 70 F1 00` | "can corrupt subsequent prints" (peripage-python) |
| `10 FF 12 tL tH` | sets the auto-off timer |
| `10 FF 10 01 n` | sets the speed cap, saved permanently *(A6 doc)* |

## Printer light

| Light | Meaning |
|---|---|
| green | on, nothing connected |
| blue | a device is connected |
| red | lid open or no paper |

No command to control the light is known.
