# Joomla 6 component development environment

Joomla 6.1 + PHP 8.4 + MariaDB 10.5.29 behind a trusted-TLS reverse proxy, with
Xdebug and a mail catcher. Clone, two commands, `https://joomla.test`.

The database version is pinned to match production. Changing it in
`compose.yaml` requires `make destroy` first — MariaDB cannot open data files
from a different major version. See [SPEC.md](SPEC.md) §3.3.

See [SPEC.md](SPEC.md) for why it is built this way.

## Requirements

- Docker with Compose v2
- [mkcert](https://github.com/FiloSottile/mkcert) — `pacman -S mkcert nss` ·
  `brew install mkcert nss` · `choco install mkcert`
- `make`

**Windows:** run everything from WSL2. Docker Desktop is WSL2-backed anyway, so
`make` is already there.

## First run

```
make setup     # .env, certificate, prints the hosts line
make up        # ~1 min on first run — installs Joomla
```

That gives you a working Joomla 6 site. Adding a component is the next section.

`make setup` runs `mkcert -install`, which **asks for your sudo password** to put
the local CA into the system trust store. That is the one privileged step; it is
not a hang. Restart the browser afterwards.

It then prints a line to add to your hosts file — it does not edit system files
itself:

```
127.0.0.1 joomla.test mail.joomla.test
```

`/etc/hosts` on Linux/macOS, `C:\Windows\System32\drivers\etc\hosts` on Windows
(as Administrator).

Then:

| | |
|---|---|
| Site | https://joomla.test |
| Admin | https://joomla.test/administrator |
| Mail | https://mail.joomla.test |

Admin credentials are in `.env` (`devpassword123` by default — Joomla requires
12+ characters).

## Developing a component

Create it under `src/`, one directory per component:

```
src/com_yours/
├── com_yours.xml          # manifest
├── admin/                 # -> administrator/components/com_yours
├── site/                  # -> components/com_yours
└── media/                 # -> media/com_yours
```

Then edit, and:

```
make deploy COMPONENT=com_yours
```

That zips the source and runs Joomla's real installer, so every change is
validated against your manifest the same way a user's install would be. Refresh
the browser to see it.

`COMPONENT` has no default — the directory name under `src/` is always explicit,
so `deploy` cannot install something you did not mean.

Reinstalling over an existing version is the normal path and is what `deploy`
does. For a genuinely clean slate — renamed element, changed table schema —
remove it first:

```
make uninstall            # lists components and their ids
make uninstall ID=252
```

Shipping it to a real site:

```
make package COMPONENT=com_yours   # -> dist/com_yours.zip
```

## All commands

Run `make` on its own for the list.

| | |
|---|---|
| `setup` | One-time per machine: `.env`, certificates, hosts line |
| `up` | Start everything |
| `down` | Stop, keep data |
| `destroy` | Stop and delete all data — full reset |
| `deploy` | Package and install `COMPONENT` |
| `package` | Write `dist/COMPONENT.zip` for a real site |
| `uninstall` | Remove an extension by id |
| `shell` | Bash in the Joomla container |
| `cli` | Joomla CLI, e.g. `make cli ARGS="config:get"` |
| `logs` | Tail all services |
| `db` | MariaDB shell |

## Xdebug

Listens on port 9003 and stays idle until triggered, so there is no constant
slowdown. Use a browser extension ("Xdebug helper") or append
`?XDEBUG_TRIGGER=1`.

**Path mapping is required.** Because components install from a zip, the
debugger reports the *installed* paths, not your sources. Map them per
component:

| Host | Container |
|---|---|
| `src/com_yours/admin` | `/var/www/html/administrator/components/com_yours` |
| `src/com_yours/site` | `/var/www/html/components/com_yours` |
| `src/com_yours/media` | `/var/www/html/media/com_yours` |

**PhpStorm:** Settings → PHP → Servers → add `joomla.test`, port 443, debugger
Xdebug, tick "Use path mappings", enter the pairs above.

**VS Code** (`.vscode/launch.json`):

```json
{
  "version": "0.2.0",
  "configurations": [{
    "name": "Xdebug",
    "type": "php",
    "request": "launch",
    "port": 9003,
    "pathMappings": {
      "/var/www/html/administrator/components/com_yours": "${workspaceFolder}/src/com_yours/admin",
      "/var/www/html/components/com_yours": "${workspaceFolder}/src/com_yours/site",
      "/var/www/html/media/com_yours": "${workspaceFolder}/src/com_yours/media"
    }
  }]
}
```

To debug Joomla core instead, map `/var/www/html` to a local copy of the
matching Joomla release.

## Mail

Joomla is configured to SMTP into Mailpit, so nothing ever leaves the machine.
Everything it sends shows up at https://mail.joomla.test.

## Troubleshooting

**Browser does not trust the certificate.** `mkcert -install` was skipped or the
browser was not restarted. Firefox additionally needs the `nss` package. Check
with `curl --cacert "$(mkcert -CAROOT)/rootCA.pem" https://joomla.test/` — if
that works but the browser does not, it is a trust-store problem, not a
certificate problem.

**Containers do not come back after a reboot.** Deliberate — there is no restart
policy, so the stack does not silently reclaim ports 80/443 on every boot. Run
`make up` (~10s once images are cached).

**Ports 80/443 already in use.** Set `HTTP_PORT` / `HTTPS_PORT` in `.env`. The
URL then needs the port: `https://joomla.test:8443`.

**Cannot reach the site from another device.** Intended: ports bind to
`127.0.0.1` only. The admin credentials in `.env.example` are public in this
repo, so binding all interfaces would expose the admin panel to everyone on the
network. To test from a phone, drop the `127.0.0.1:` prefix in `compose.yaml`
**and** change `JOOMLA_ADMIN_PASSWORD` in your `.env` first.

**`make up` says Joomla did not install.** `make logs` — usually the database
volume is half-initialised from an interrupted first run. `make destroy && make up`
fixes it.

**Site loads but CSS/links are `http://`.** `docker/proxy.conf` did not load;
rebuild with `make up`.

**Changes not showing.** `make deploy` again — editing `src/` alone changes
nothing until it is installed. That is the deliberate trade-off of this setup;
see SPEC.md §10.

## License

MIT — see [LICENSE](LICENSE).
