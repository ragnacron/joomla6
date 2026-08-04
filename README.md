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

That gives you a working Joomla 6 site. Installing an extension is the next section.

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

## Installing your extension

This environment installs a zip you already built. It does not build anything —
your extension's own repository already knows which files are sources and which
are artefacts, and its build script produces a clean zip. Duplicating that here
could only do it worse.

```
./build.sh                                   # whatever your repo already uses
make deploy ZIP=~/code/pkg_hello/dist/pkg_hello.zip
```

`ZIP` is any host path to a built extension zip — component, module, plugin, or
a full `pkg_*` package with its nested zips. It goes through Joomla's real
installer, so every deploy is validated exactly the way a user's install is.
Refresh the browser to see it.

Anything that is not an existing `*.zip` is refused. Joomla also accepts
`.tar.gz` and `.tar.bz2`; this deliberately does not, since Joomla extensions
ship as zips.

Working inside an extension repo all day? Add a shell alias:

```
alias jdeploy='make -C ~/code/joomla6 deploy ZIP=$PWD/dist/pkg_hello.zip'
```

### Deleting a file does not delete it from the site

Joomla's installer copies files in; it never removes files that disappeared from
your package. A stale file keeps running until you remove the extension. This is
not a quirk of this setup — it is exactly what your users get when they upgrade
your extension over an older version, which is worth seeing during development
rather than in a bug report.

For a genuinely clean slate — a deleted file, a renamed element, a changed table
schema:

```
make uninstall                     # lists packages and their ids
make uninstall ID=<id>             # the id from that listing
make deploy ZIP=~/code/pkg_hello/dist/pkg_hello.zip
```

Removing a package id also removes every extension that package installed, so
one id is usually all you need. `uninstall` works on any extension type — only
the convenience listing is filtered, and it defaults to `package` because that
is the usual deliverable:

```
make uninstall                     # packages          (2 rows on a fresh site)
make uninstall TYPE=component      # components       (37)
make uninstall TYPE=plugin         # plugins         (157)
make uninstall TYPE=               # every type      (254)
```

## All commands

Run `make` on its own for the list.

| | |
|---|---|
| `setup` | One-time per machine: `.env`, certificates, hosts line |
| `up` | Start everything |
| `down` | Stop, keep data |
| `destroy` | Stop and delete all data — full reset |
| `deploy` | Install a built zip from `ZIP=<path>` |
| `uninstall` | Remove any extension by id; no id lists `TYPE` (default `package`) |
| `shell` | Bash in the Joomla container |
| `cli` | Joomla CLI, e.g. `make cli ARGS="config:get"` |
| `logs` | Tail all services |
| `db` | MariaDB shell |

## Xdebug

Listens on port 9003 and stays idle until triggered, so there is no constant
slowdown. Use a browser extension ("Xdebug helper") or append
`?XDEBUG_TRIGGER=1`.

**Path mapping is required.** Because extensions install from a zip, the
debugger reports the *installed* paths, not your sources. Map them per
extension:

| Host (your component repo) | Container |
|---|---|
| `<repo>/admin` | `/var/www/html/administrator/components/com_hello` |
| `<repo>/site` | `/var/www/html/components/com_hello` |
| `<repo>/media` | `/var/www/html/media/com_hello` |

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
      "/var/www/html/administrator/components/com_hello": "${workspaceFolder}/admin",
      "/var/www/html/components/com_hello": "${workspaceFolder}/site",
      "/var/www/html/media/com_hello": "${workspaceFolder}/media"
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

**Changes not showing.** Rebuild the zip, then `make deploy ZIP=...` again —
editing your source alone changes nothing until it is rebuilt and installed. That is the deliberate trade-off of this setup;
see SPEC.md §10.

## License

MIT — see [LICENSE](LICENSE).
