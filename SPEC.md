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
| Joomla version | `joomla:6.1-php8.4-apache` (official image) | Floating minor tag: every 6.1.x patch arrives on the next `make up`, which builds with `--pull`. Deliberately the opposite of the MariaDB pin below — MariaDB has to match production, Joomla only has to be current. Image is maintained and can auto-install, skipping the web installer. |
| PHP | 8.4 | Joomla 6 requires ≥ 8.3, recommends 8.4. |
| Database | MariaDB **10.5.29**, pinned | Matches the production server exactly, so schema and SQL behaviour are tested against what the code will actually run on. See §3.3. |
| TLS | mkcert on the host + Caddy in a container | mkcert installs its root CA into the OS/browser trust store on all three platforms with one command. Caddy is a 6-line config and no Dockerfile. |
| Hostname | `joomla.test`, `mail.joomla.test` | RFC 6761 reserved. Avoids the mDNS collision `.local` has on Arch/Avahi and macOS. |
| Component workflow | install a pre-built zip via `extension:install` | Exercises the real installer. Building the zip belongs to the extension's own repo, which knows its artefacts from its sources. See §6. |
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
│   └── proxy.conf               # makes PHP see HTTPS behind Caddy
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

The webroot is the named volume `joomla_data`, and the image's entrypoint only populates an
*empty* one. So a newer image never reaches a stack that already has a site in it: a Joomla
upgrade needs `make destroy` first, exactly like the MariaDB bump in §3.3.

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

## 6. The deploy workflow — **[revised twice]**

**This environment does not build anything.** It installs a zip you already
built. Extensions are developed in their own repositories, which have their own
build scripts that know which files are artefacts and which are sources.

```
make deploy ZIP=~/code/pkg_hello/dist/pkg_hello.zip
```

1. `compose cp "$ZIP" joomla:/tmp/deploy.zip`
2. `exec php cli/joomla.php extension:install --path=/tmp/deploy.zip`

That is the entire mechanism. Any host path works, absolute or relative;
switching projects needs no config change and no restart.

### How it got here

Two earlier designs were wrong, and both were wrong in the same direction —
this repo trying to do a job that belongs to the extension's own repo.

1. **Bind-mount `./src`, zip it in-container.** Forced every component to live
   inside this repository. Replaced by `docker compose cp` from any path.
2. **`compose cp` a directory, then zip it in-container** with `docker/zip.php`
   (PHP's `ZipArchive`, chosen because `zip` is absent on Windows and in the
   Debian-based image). Still wrong: zipping a source directory wholesale sweeps
   in `.git`, `node_modules` and tests, and it cannot express a *package*
   (`pkg_*`) at all — those contain several extensions plus nested zips, which
   no naive directory walk produces.

Accepting only a built zip deleted `zip.php` entirely, along with the
`/tmp/build` wipe that stopped deleted files lingering, the `NAME` derivation,
and the cross-platform packaging rationale. The build problem was never this
repo's to solve.

`deploy` rejects anything that is not an existing `*.zip`. Joomla's installer
also accepts `.tar.gz` and `.tar.bz2`; restricting to zip is deliberate, since
that is what Joomla extensions actually ship as. Relaxing it is one `case` arm.

`extension:install` on an already-installed extension runs the installer's
update path, so one target covers first install and every subsequent change.

### What the installer will not do

Joomla's installer copies files in; it never deletes files that vanished from
your package. A stale file keeps running until the extension is removed.

This is not worth working around. It is precisely what a user gets upgrading
your extension over an older version, so seeing it during development is a
feature of using the real installer. `make uninstall` then `make deploy` is the
clean slate.

**[revised]** The planned `make reinstall` is now `make uninstall ID=<id>`.
`extension:remove` needs a numeric id, and the only way to get one is
`extension:list`, which prints a human-readable table with no machine-readable
format. Parsing that table inside a Makefile is exactly the kind of thing that
breaks silently a year later, so `make uninstall` with no `ID` just prints the
list and asks for the id. Two seconds of human, zero fragile shell.

`extension:remove` accepts **any** extension type, and removing a package id
also removes every extension that package installed — verified. Only the
convenience listing was ever component-only, which made packages look
unsupported. It now takes `TYPE`, defaulting to `package` since that is the
usual deliverable here:

| `TYPE` | rows on a fresh site |
|---|---|
| `package` (default) | 3 |
| `component` | 38 |
| `plugin` | 157 |
| empty — every type | 254 |

The default matters more than it looks: an unfiltered list is 254 rows, which is
not a picker, it is a haystack. Filtering by non-core (`protected=0`) would be
sharper still, but that means SQL and a hardcoded table prefix in the Makefile —
a worse trade than one `TYPE` variable.

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
| `deploy` | Install a built zip from `ZIP=<host path>` |
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
| 2 | Joomla installs unattended, no web installer | Joomla 6.1.3 / PHP 8.4.24 |
| 3 | `https://joomla.test` and `/administrator` | 200, 200 |
| 4 | `http://` → `https://` | 308 |
| 5 | Generated URLs use `https://` | all `https://joomla.test/...` |
| 6 | `make deploy` installs | "Extension installed successfully" |
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
| 22 | `extension:remove` on a **package** id | removes the package and cascades to its component — rows and files both gone |
| 23 | `uninstall` listing for `TYPE=package` / `component` / empty | 3 / 38 / 254 rows |
| 19 | Deploy a zip from **outside** this repo | ✓ absolute and relative paths |
| 19a | A real `pkg_*` package with a nested component zip | both rows registered: `package Hello Package`, `component Example` |
| 20 | Missing, non-existent, or non-zip `ZIP` | each refused with its own message |
| 21 | File deleted from a rebuilt zip | still on the site — installer behaviour, §6 |
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
