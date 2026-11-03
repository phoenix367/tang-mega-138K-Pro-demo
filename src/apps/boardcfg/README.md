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
| `net` | `dhcp` or `static` (default `static`) | applied by `/etc/init.d/S40network`, see below |
| `ip` | `A.B.C.D` or `A.B.C.D/N` (default `192.168.200.2/24`) | static mode address; a bare address means `/24` |
| `gateway` | `A.B.C.D` | static mode default route; unset = none (DHCP brings its own) |
| `dns` | `"A.B.C.D [A.B.C.D ...]"`, up to three | static mode `/etc/resolv.conf`; unset = the gateway, else `192.168.200.1` |
| anything else | stored and restored verbatim | `serial`, ... up to 64 keys, key ≤ 31 and value ≤ 127 chars, 736 bytes of text in all |

Typical first-time setup over ssh/UART:

```sh
boardcfg set mac 02:ae:35:00:00:01     # locally administered unicast
boardcfg set hostname tang-mega
boardcfg set serial TM138K-0001
boardcfg set gateway 192.168.200.1     # or: boardcfg set net dhcp
boardcfg set dns "192.168.200.1 8.8.8.8"
boardcfg show -e
reboot                                  # eth0 now comes up with the stored MAC
```

### Network keys

`S40network` configures `lo` and `eth0` from these keys at boot (after
`S35boardcfg` has restored them) and writes the one-line summary of what it did
to `/run/network.state`. The daemon rebuilds that line from the settings after
every change; when it differs (or the MAC was changed, which drops the routes
and any lease) it runs `S40network restart`, so `boardcfg set ip ...` or
`boardcfg set net dhcp` takes effect at once. An ssh session on the old address
is lost at that point, as expected; the UART console is not.

- **static**: `ifconfig eth0 ip netmask ...`, `route add default gw`, resolv.conf
  from `dns` (or the gateway, or the shipped `192.168.200.1`), `options timeout:1
  attempts:1` so reverse lookups on a serverless link fail fast.
The desktop's Network panel has a **Configure** button that edits the same keys
(plus hostname and MAC) in a dialog and applies them through `boardcfg set`.

- **dhcp**: busybox `udhcpc -i eth0 -b -R -x hostname:$(hostname)` with
  `/usr/share/udhcpc/default.script` (address, default route(s), resolv.conf with
  the lease's `search`/`nameserver`, a `net: eth0 ...` line in the kernel log).
  It tries four times at two-second intervals in the foreground, then keeps
  retrying every five seconds in the background, so a board without a DHCP
  server simply has no address until one appears. `S40network stop` releases the
  lease (`-R`).

## The daemon

`boardcfg -d` first does `load` synchronously (EEPROM → `/etc/board.conf`, apply),
so by the time `S35boardcfg` returns the hostname, zone and MAC are set, before
`S40network` brings eth0 up with the stored network keys (`/run/network.state`
does not exist yet at that point, so `load` itself never touches the network). It then forks and watches `/etc` with inotify for
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
