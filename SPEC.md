# Joomla 6 local development environment — Spec

A git repository that gives any developer a working Joomla 6 site at
`https://joomla.test` with a trusted certificate, in two commands, on Linux,
macOS and Windows. Purpose: developing Joomla **components**.

Status: built and verified end-to-end (see §9). Three things changed during the
build because reality disagreed with the spec — marked **[revised]** below.

---

## 1. Decisions

| Decision | Choice | Why |
|---|---|---|
| Joomla version | `joomla:6.1-php8.4-apache` (official image) | Joomla 6 is current (6.1.2). Image is maintained and can auto-install, skipping the web installer. |
| PHP | 8.4 | Joomla 6 requires ≥ 8.3, recommends 8.4. |
| Database | MariaDB **10.5.29**, pinned | Matches the production server exactly, so schema and SQL behaviour are tested against what the code will actually run on. See §3.3. |
| TLS | mkcert on the host + Caddy in a container | mkcert installs its root CA into the OS/browser trust store on all three platforms with one command. Caddy is a 6-line config and no Dockerfile. |
| Hostname | `joomla.test`, `mail.joomla.test` | RFC 6761 reserved. Avoids the mDNS collision `.local` has on Arch/Avahi and macOS. |
| Component workflow | zip + `extension:install` | Exercises the real manifest and installer on every change; catches packaging bugs that a symlinked dev tree hides. |
| Joomla webroot | named volume, **not** bind-mounted | Fast file I/O on macOS/Windows. Nothing to gain from bind-mounting core when the component ships as a zip. |
| Extras | Xdebug, Mailpit, Makefile | Chosen. No Adminer. |

Explicitly **not** in scope: production hardening, multi-site, PostgreSQL,
CI pipelines, Joomla core contribution (that needs a bind-mounted core).

---

## 2. Repository layout

```
joomla6-dev/
├── compose.yaml
├── Makefile
├── .env.example                 # copied to .env on first setup
├── .gitignore
├── README.md
├── Caddyfile
├── docker/
│   ├── joomla.Dockerfile        # official image + xdebug
│   ├── xdebug.ini
│   ├── proxy.conf               # makes PHP see HTTPS behind Caddy
│   └── zip.php                  # cross-platform packer, runs inside the container
└── certs/                       # gitignored — mkcert output, per machine
```

`certs/` and `.env` are gitignored. Everything else is committed, so a
fresh clone plus `make setup && make up` reproduces the environment.

---

## 3. Services

Four containers on one user-defined bridge network. Only Caddy publishes ports.

### 3.1 `caddy` — TLS terminator

- Image: `caddy:2-alpine`, unmodified.
- Publishes `127.0.0.1:${HTTP_PORT:-80}:80` and `127.0.0.1:${HTTPS_PORT:-443}:443` — loopback only, because `.env.example` ships a known admin password.
- Mounts `./Caddyfile` and `./certs` read-only.

```caddyfile
joomla.test {
	tls /certs/joomla.test.pem /certs/joomla.test-key.pem
	reverse_proxy joomla:80
}

mail.joomla.test {
	tls /certs/joomla.test.pem /certs/joomla.test-key.pem
	reverse_proxy mailpit:8025
}
```

Caddy redirects `:80` → `:443` on its own. It sets `X-Forwarded-Proto`, which
§5 makes Joomla trust.

### 3.2 `joomla` — the site

Built from `docker/joomla.Dockerfile`:

```dockerfile
FROM joomla:6.1-php8.4-apache
RUN pecl install xdebug && docker-php-ext-enable xdebug
COPY xdebug.ini /usr/local/etc/php/conf.d/zz-xdebug.ini
```

Volumes:
- `joomla_data:/var/www/html` — the whole Joomla tree, named volume.

No bind mount for component sources. See §6.

Environment (drives the entrypoint's unattended CLI install — no web installer):

```
JOOMLA_DB_HOST=db
JOOMLA_DB_USER=joomla
JOOMLA_DB_PASSWORD=joomla
JOOMLA_DB_NAME=joomla
JOOMLA_SITE_NAME=Joomla 6 Dev
JOOMLA_ADMIN_USER=Dev Admin
JOOMLA_ADMIN_USERNAME=admin
JOOMLA_ADMIN_PASSWORD=<12+ chars>        # Joomla rejects shorter
JOOMLA_ADMIN_EMAIL=dev@joomla.test
JOOMLA_SMTP_HOST=mailpit
JOOMLA_SMTP_HOST_PORT=1025
```

All values come from `.env` so credentials are per-machine, not committed.

### 3.3 `db` — MariaDB, pinned to production

- Image: `mariadb:10.5.29` — deliberately pinned, not a floating `10.5`.
- Volume `db_data:/var/lib/mysql`.
- Healthcheck `healthcheck.sh --connect --innodb_initialized`; `joomla` waits on
  `condition: service_healthy` so the installer never races the DB. Both flags
  exist in the 10.5 image (checked — they are not 11.x-only), as do the
  `MARIADB_*` environment variables.

Production reports `10.5.29-MariaDB-0+deb11u1-log`; this image reports
`10.5.29-MariaDB-ubu2004`. Same upstream server version, which is what governs
SQL and schema behaviour — the difference is only the distro the package was
built on, and the `-log` suffix, which just means binary logging is on in
production. Neither is worth reproducing locally.

Two facts worth stating plainly rather than discovering later:

- **Joomla 6 requires MariaDB ≥ 10.4**, so 10.5 is supported but close to the
  floor. Anything Joomla drops next will hit production first.
- **MariaDB 10.5 reached end of life in June 2025.** That is production's
  situation, not this repo's problem, but matching it means this environment is
  pinned to an unmaintained branch on purpose.

Changing the version is a data-file downgrade or upgrade, so it needs
`make destroy` first — `make up` alone will fail to start on an incompatible
volume. That is the mechanism for testing a production upgrade before it
happens: change the tag, `make destroy && make up && make deploy`.

### 3.4 `mailpit`

- Image: `axllent/mailpit`.
- No published ports — reached at `https://mail.joomla.test` through Caddy.
- Catches every mail Joomla sends. Nothing leaves the machine.

---

## 4. TLS and hostname

Per machine, once:

```
mkcert -install
mkcert -cert-file certs/joomla.test.pem -key-file certs/joomla.test-key.pem \
       joomla.test "*.joomla.test"
```

The wildcard covers `mail.joomla.test` and any future subdomain on the same cert.

Hosts file — one line, still required on every OS:

```
127.0.0.1 joomla.test mail.joomla.test
```

- Linux/macOS: `/etc/hosts`
- Windows: `C:\Windows\System32\drivers\etc\hosts` (as Administrator)

`make setup` generates the certs and prints the exact hosts line; it does not
edit system files itself.

Installing mkcert: Arch `pacman -S mkcert nss`, macOS `brew install mkcert nss`,
Windows `choco install mkcert` or `scoop install mkcert`.

---

## 5. Joomla behind the proxy — **[revised]**

Caddy terminates TLS, so PHP sees plain HTTP and Joomla would otherwise emit
`http://` URLs and break admin redirects.

The original plan was `config:set behind_loadbalancer=1`. **That key does not
exist in Joomla 6** — it is a Joomla 4/5 setting, and `config:set` refuses keys
outside the current config list:

```
[ERROR] Can't find option *behind_loadbalancer* in configuration list
```

Solved one layer down instead, in `docker/proxy.conf`:

```apache
SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on
ServerName joomla.test
```

This makes `$_SERVER['HTTPS']` correct for *all* PHP, so core and every
extension see HTTPS without any Joomla configuration. It is also strictly more
robust than the config approach, which only fixed core's own URL generation.

`force_ssl` is deliberately **not** set: with TLS terminated upstream it would
redirect-loop, and Caddy already 308s `:80` → `:443`.

Two dev-only settings remain in `make up`:

```
php cli/joomla.php config:set debug=1 error_reporting=maximum
```

The image's entrypoint has no init-hook directory, so `make up` polls for
`configuration.php` (max ~120s) and then applies them. Idempotent, so re-running
`make up` is safe.

---

## 6. The component workflow

`extension:install --path=` requires a **zip** — it calls
`InstallerHelper::unpack()` and rejects a plain directory. So every change is
packaged before installing.

Packaging runs *inside* the container via `docker/zip.php` using PHP's
`ZipArchive`, rather than on the host. Rationale: `zip` is not present on
Windows and the Debian-based Joomla image, and PHP's zip extension is a hard
Joomla requirement — so it is guaranteed present exactly where we need it. One
code path, three platforms, no `tar`/`Compress-Archive` divergence.

### Sources live in other repositories — **[revised]**

Components are developed in their own repositories, so this one holds none of
them. The original design bind-mounted `./src` into the container; that forces
every component to live inside this repo, or forces a per-machine path in `.env`
plus a container recreate whenever you switch projects.

The mount existed only so `zip.php` could read the source. `docker compose cp`
removes that need entirely, and with it the mount, the `src/` directory, and any
configuration:

`make deploy SRC=<any host path>`, where the directory's basename is the
component name:

1. `exec rm -rf /tmp/build` — or files deleted from the source linger in the zip
2. `compose cp "$SRC" joomla:/tmp/build`
3. `exec php /usr/local/bin/zip.php /tmp/build /tmp/<name>.zip`
4. `exec php cli/joomla.php extension:install --path=/tmp/<name>.zip`

Any path works — absolute, relative, with or without a trailing slash, and a
component nested anywhere inside its repository. Switching projects needs no
config change and no restart. Copy cost is negligible at component size.

`extension:install` on an already-installed extension runs the installer's
update path, so the same target covers first install and every subsequent
change — verified.

### What the installer will not do

Joomla's installer copies files in; it never deletes files that vanished from
your package. Verified: a file removed from the source is correctly absent from
the zip, and still present on the site afterwards.

This is not worth working around. It is precisely what a user gets upgrading
your component over an older version, so seeing it during development is a
feature of using the real installer. `make uninstall` then `make deploy` is the
clean slate.

**[revised]** The planned `make reinstall` is now `make uninstall ID=<id>`.
`extension:remove` needs a numeric id, and the only way to get one is
`extension:list`, which prints a human-readable table with no machine-readable
format. Parsing that table inside a Makefile is exactly the kind of thing that
breaks silently a year later, so `make uninstall` with no `ID` just prints the
list and asks for the id. Two seconds of human, zero fragile shell.

`SRC` has no default, so `deploy` can never install something you did not name.

### Sample component — removed

A minimal `com_example` (manifest, admin and site view, one CSS file) shipped
initially as the smoke test, and is what §9 was verified against. It was removed
once that verification was done: a repository whose purpose is hosting *your*
components should not ship a toy one that must be kept in sync with Joomla's
evolving MVC conventions.

---

## 7. Xdebug

`docker/xdebug.ini`:

```ini
xdebug.mode=debug,develop
xdebug.start_with_request=trigger
xdebug.client_host=host.docker.internal
xdebug.client_port=9003
xdebug.idekey=PHPSTORM
```

`start_with_request=trigger` means Xdebug is idle until a `XDEBUG_TRIGGER`
cookie or query parameter is present — the browser extension sets it. No
constant 2× slowdown just because the container is running.

`host.docker.internal` is not native on Linux, so the `joomla` service declares
`extra_hosts: ["host.docker.internal:host-gateway"]`. Harmless on macOS and
Windows, so it goes in unconditionally rather than in a platform override.

**Path mapping is required.** Because the component is installed from a zip, the
files the debugger reports are the *installed* copies, not your sources. The IDE
needs, per component:

| Host (inside your component repo) | Container |
|---|---|
| `<repo>/admin` | `/var/www/html/administrator/components/com_hello` |
| `<repo>/site` | `/var/www/html/components/com_hello` |
| `<repo>/media` | `/var/www/html/media/com_hello` |

The README documents this with a PhpStorm and a VS Code `launch.json` example.
This is the real cost of the zip-install workflow; it is paid once per project.

---

## 8. Makefile

`make` is the only interface. Every target is `docker compose` underneath —
nothing is hidden that you cannot run by hand.

| Target | Does |
|---|---|
| `setup` | Copy `.env.example` → `.env`, run mkcert, print the hosts line |
| `up` | Build + start, wait for install, apply §5 config |
| `down` | Stop, keep data |
| `destroy` | Stop and delete both volumes — full reset |
| `deploy` | Build + install from `SRC=<host path>` |
| `uninstall` | Remove by id; with no `ID`, lists them |
| `shell` | Bash in the joomla container |
| `cli` | Pass through to `cli/joomla.php`, e.g. `make cli ARGS="config:get"` |
| `logs` | Tail all services |
| `db` | MariaDB shell |

**Windows:** run from WSL2. Docker Desktop on Windows is WSL2-backed anyway, so
`make` is already available there; supporting `cmd.exe` natively would mean
maintaining a second set of scripts for no gain.

---

## 9. Verification

Run on Arch Linux, Docker 29.6 / Compose 5.3, from an empty directory. Rows
6–12 used the `com_example` sample described in §6, which was removed after
these results were recorded.

| # | Check | Result |
|---|---|---|
| 1 | Stack builds; Xdebug compiles against PHP 8.4 | 3.5.3, `mode=debug,develop`, `start_with_request=trigger` |
| 2 | Joomla installs unattended, no web installer | Joomla 6.1.2 / PHP 8.4.24 |
| 3 | `https://joomla.test` and `/administrator` | 200, 200 |
| 4 | `http://` → `https://` | 308 |
| 5 | Generated URLs use `https://` | all `https://joomla.test/...` |
| 6 | `make deploy` packages and installs | 10 files, "Extension installed successfully" |
| 7 | Files land in all three roots | `administrator/components/`, `components/`, `media/` |
| 8 | Registered and enabled in the DB | `Example  252  1.0.0  component  Yes` |
| 9 | Site view renders (through the SEF router) | ✓ |
| 10 | Admin view renders, logged in | ✓, menu entry present |
| 11 | Media CSS serves | 200 |
| 12 | **Edit → `make deploy` → refresh** | ✓, and reinstall-over-existing works |
| 13 | Joomla configured for Mailpit; mail arrives | `mailer=smtp host=mailpit:1025`, inbox count 1 |

| 15 | Real mkcert certificate, chain verified | `verify=0` on site, admin and mail |
| 15a | Joomla 6.1 installs on MariaDB 10.5.29 | 76 tables, `10.5.29-MariaDB-ubu2004`, site + component OK |
| 16 | `make destroy` → `up` → `deploy` from nothing | full stack + component back in **11.7s** (images cached) |
| 17 | `help`, `cli`, `db`, `uninstall` listing | all pass |
| 19 | Deploy from a directory **outside** this repo | ✓ absolute, relative, and trailing-slash paths |
| 20 | Missing / non-existent `SRC` | refused with a usage line |
| 21 | File deleted from source | absent from the zip, still on the site — installer behaviour, §6 |
| 18 | `make uninstall ID=<id>` actually removing | **initially broken**, see below |

Row 18 is the one that got away. `make uninstall` was only ever exercised on its
no-`ID` listing branch, so two bugs shipped in the removal branch: the id is a
positional argument, not `--id=`, and the command prompts for confirmation,
which `exec -T` cannot answer. Both fixed (`extension:remove $(ID) -n`) and the
removal verified against the database and the filesystem. The lesson is narrow
and worth naming: a target with two branches needs both branches run.

Row 12 is the loop that matters; row 16 is what makes this a repository rather
than one machine's setup.

Two things are **not** measured:

- **macOS and Windows/WSL2.** The image is multi-arch and every host-side step is
  `make` + `mkcert`, but that is an expectation, not a result.
- **Browser trust.** `mkcert -install` needs sudo, so the CA is not in this
  machine's system store yet. The chain itself verifies against the mkcert root
  (`curl --cacert "$(mkcert -CAROOT)/rootCA.pem"` → 200, `verify=0`), which
  proves Caddy is serving the right certificate; what remains is purely the
  trust-store step.

---

## 10. Known trade-offs

- **Deploy takes a few seconds** rather than being instant. Bought deliberately:
  every change goes through the real installer.
- **Core is not on the host.** Reading Joomla core means `make shell`. If core
  reading turns out to be frequent, adding a read-only bind mount of the webroot
  is a one-line change later.
- **`.test` still needs a hosts entry** on every machine. No local TLD avoids
  this on all three platforms.
- **Certs are per-machine.** `certs/` is gitignored because mkcert's CA is
  machine-local; committing a key would be both useless and wrong.

---

## Sources

- [Joomla 6.0 and Joomla 5.4 are here!](https://www.joomla.org/announcements/release-news/joomla-6-0-and-joomla-5-4-are-here.html)
- [Joomla Technical Requirements](https://manual.joomla.org/docs/next/get-started/technical-requirements/)
- [joomla — Official Docker Image](https://hub.docker.com/_/joomla)
- [joomla-docker/docker-joomla](https://github.com/joomla-docker/docker-joomla)
- [Joomla CLI — Using the CLI](https://guide.joomla.org/user-manual/command-line-interface/command-line-interface-using-the-cli)
- [Installing Joomla extensions from the command line](https://www.dionysopoulos.me/installing-joomla-extensions-from-the-command-line.html)
