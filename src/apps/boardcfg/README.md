# boardcfg — board settings in the Dock EEPROM

The rootfs is an initramfs, so nothing written on the board survives a reboot.
`boardcfg` keeps a small set of settings in the Dock's 1 KB ZD24C08A EEPROM
(see `src/rtl/gpio/README.md` for the hardware path) and restores them at boot.
Static musl binary at `/usr/sbin/boardcfg`, started by `/etc/init.d/S35boardcfg`.

```
boardcfg                     show /etc/board.conf
boardcfg get KEY             print one value
boardcfg set KEY VALUE       change a value; the daemon writes it to the EEPROM and
                             applies it (without the daemon, set does both itself)
boardcfg unset KEY
boardcfg show -e             decode what the EEPROM holds
boardcfg load                EEPROM -> /etc/board.conf, apply (what boot does)
boardcfg sync                /etc/board.conf -> EEPROM, apply
boardcfg erase               invalidate the EEPROM block
boardcfg -d                  load, then stay in the background as the daemon
```

## Keys

| Key | Applied how | Notes |
|---|---|---|
| `mac` | eth0 hardware address (`SIOCSIFHWADDR`, interface bounced if up) | also read by the **kernel** at boot: the DT gives `gw-tse` an nvmem cell `mac-address@110` in the EEPROM and the driver defers its probe until the EEPROM is up, so eth0 has the stored address before userspace runs. Unset = random address at every boot (the previous behaviour) |
| `hostname` | `sethostname()` + `/etc/hostname` | letters, digits, `-` |
| `tz` | copies `/usr/share/zoneinfo/<tz>` to `/etc/localtime`, writes `/etc/timezone` | the desktop's Date & Time panel saves through `boardcfg set tz` (the SD-card copy is only used when boardcfg is absent) |
| anything else | stored and restored verbatim | `serial`, ... up to 64 keys, key ≤ 31 and value ≤ 127 chars, 736 bytes of text in all |

Typical first-time setup over ssh/UART:

```sh
boardcfg set mac 02:ae:35:00:00:01     # locally administered unicast
boardcfg set hostname tang-mega
boardcfg set serial TM138K-0001
boardcfg show -e
reboot                                  # eth0 now comes up with the stored MAC
```

## The daemon

`boardcfg -d` first does `load` synchronously (EEPROM → `/etc/board.conf`, apply),
so by the time `S35boardcfg` returns the hostname, zone and MAC are set, before
`S40network` brings eth0 up. It then forks and watches `/etc` with inotify for
`board.conf` being rewritten (by `boardcfg set`, an editor, or the desktop),
debounces 300 ms, validates, applies the changed settings and rewrites the
EEPROM block only when its content differs (verified by read-back). `SIGHUP`
forces a sync, `SIGTERM` stops it; pid in `/run/boardcfg.pid`; messages go to
the kernel log (`dmesg | grep boardcfg`).

## EEPROM layout

Offsets in the 1 KB part. `0x000..0x0FF` is left untouched for the vendor
(byte 0 reads 0x89 from the factory).

| Offset | Size | Content |
|---|---|---|
| 0x100 | 16 | header: `"AE35"`, version 1, flags, text length (LE16), CRC-32 (LE32, over 0x110..0x120+len), 4 reserved |
| 0x110 | 16 | MAC address (6 bytes, nvmem cell for the kernel) + 10 reserved |
| 0x120 | ≤ 736 | `key=value\n` text, without `mac` |

A missing or corrupt header (wrong magic/version/CRC) means "no settings": the
shipped `/etc/board.conf` (just `hostname=ae350`) is used and the EEPROM is not
written until the first `boardcfg set`.

## Building

`make` (static musl, soft-atomic libc as for every rootfs binary), `make install`
copies it to `linux/rootfs/usr/sbin/`. For a host-side test the paths are
overridable: `gcc -DNVMEM='"./nvmem"' -DCONF='"./etc/board.conf"' -DCONF_DIR='"./etc"'
-DPIDFILE='"./pid"' -DZONEINFO='"./zi"' boardcfg.c` against a 1 KB file.
