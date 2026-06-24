# `ghcr.io/akyrahub/php`

A **minimal, security-hardened PHP-FPM base image** built on Alpine, intended to be
extended by application images via `FROM ghcr.io/akyrahub/php:<version>`.

It ships PHP-FPM and a curated set of extensions — **nothing else**. There is no web
server, no process supervisor, no entrypoint and no init system baked in. Those are
deployment concerns and belong in *your* image; recipes for the common ones are below.

> **Why this image exists:** the upstream Debian-based `php:*-fpm-bullseye` tags drag in
> hundreds of unfixable OS CVEs (Debian 11 is EOL). This image is rebuilt on Alpine 3.23
> with `apk upgrade` on every build, targeting **0 fixable CRITICAL/HIGH** vulnerabilities
> (enforced in CI via Trivy).

---

## What's inside

| | |
|---|---|
| **Base** | `php:8.5.5-fpm-alpine3.23` |
| **PHP** | 8.5.5, FPM, listening on `:9000` |
| **User** | runs as `www-data` (UID 82) — **non-root** |
| **Timezone** | `Europe/Paris` (`TZ` env + `/etc/localtime`) |
| **Architecture** | **`linux/amd64` only** (see [Architecture](#architecture)) |
| **Shell** | `bash` is included (better DX in derived layers) |
| **Healthcheck** | `php-fpm-healthcheck` ([renatomefi](https://github.com/renatomefi/php-fpm-healthcheck) v0.5.0) wired via `HEALTHCHECK` |

### Bundled PHP extensions

`intl`, `pdo_pgsql`, `zip`, `gd` (freetype + jpeg), `bcmath`, `pcntl`, `exif`,
`sockets`, `redis` (PECL 6.3.0).

Already **built into PHP 8.5** and therefore *not* re-added (don't try to reinstall
these — it will fail): `opcache`, `mbstring`, `pdo_sqlite`, `sodium`, `mysqlnd`, `Phar`.

### Deliberately **not** included

- **`imagick`** — large CVE surface. Opt in only if you need it ([recipe](#imagick-opt-in)).
- **`gd` with WebP/AVIF** — `gd` is compiled with freetype + jpeg only. If you need
  WebP or AVIF you must recompile `gd` ([recipe](#webp--avif-support)).
- **nginx / Caddy / Apache, supervisord, tini, an entrypoint** — by design. See recipes.

---

## Tags & versioning

Pushed by CI:

| Tag form | Example | Floating? | Use for |
|---|---|---|---|
| `<X.Y.Z>` | `1.0.0` | no | **production — pin this** |
| `<X.Y.Z>-php<ver>-alpine<ver>` | `1.0.0-php8.5.5-alpine3.23` | no | fully reproducible builds |
| `8`, `8.5`, `8.5.5-alpine3.23` | — | yes (moves on every `trunk` push) | local dev / tracking latest patch |

There is intentionally **no `:latest` tag**. For anything you ship, pin an immutable
`X.Y.Z` (or the longer `…-php…-alpine…`) tag — the floating `8` / `8.5` tags move
underneath you.

```dockerfile
# Production: pin an immutable version
FROM ghcr.io/akyrahub/php:1.0.0
```

The package is private; authenticate to GHCR before pulling:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <username> --password-stdin
docker pull ghcr.io/akyrahub/php:1.0.0
```

---

## Quick start

```dockerfile
FROM ghcr.io/akyrahub/php:1.0.0

WORKDIR /var/www/html

# Install Composer dependencies (multi-stage keeps the Composer binary out of the runtime)
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

COPY . .
# CMD inherited from the base = php-fpm
```

The base already sets `USER www-data`, exposes `:9000` and defines a `HEALTHCHECK`,
so a derived image needs nothing extra to run FPM.

---

## Extending the image

### Adding PHP extensions

Add a build layer, compile against `*-dev` headers, then **purge them in the same
`RUN`** so they never land in the final image. Pin every package to your Alpine
branch (`~MAJOR.MINOR`) and verify with `apk search -e <pkg>` inside the image first —
don't guess versions.

```dockerfile
FROM ghcr.io/akyrahub/php:1.0.0

USER root
RUN set -eux \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
         # ...your -dev headers, pinned to ~MAJOR.MINOR... \
    && docker-php-ext-install -j"$(nproc)" soap \
    && apk del .build-deps \
    && rm -rf /tmp/* /var/cache/apk/*
USER www-data
```

> Switch back to `USER www-data` at the end of every layer that needed root.

### WebP / AVIF support

The base `gd` has freetype + jpeg only. To add WebP/AVIF you reconfigure and rebuild
`gd`, and you must also keep the **runtime** libs (`libwebp`, `libavif`) installed —
otherwise PHP fails at load with `cannot open shared object`.

```dockerfile
USER root
RUN set -eux \
    # runtime libs — verify exact versions with `apk search -e libwebp libavif`
    && apk add --no-cache libwebp libavif \
    && apk add --no-cache --virtual .gd-deps \
         $PHPIZE_DEPS libwebp-dev libavif-dev \
         libpng-dev libjpeg-turbo-dev freetype-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif \
    && docker-php-ext-install -j"$(nproc)" gd \
    && apk del .gd-deps \
    && rm -rf /tmp/* /var/cache/apk/*
USER www-data
```

### Imagick (opt-in)

Imagick has a wide CVE surface, so it is excluded from the base. If you need it,
install it **and harden ImageMagick's `policy.xml`** to disable risky coders
(MSL/MVG/EPHEMERAL/URL/etc.) and cap resources.

```dockerfile
USER root
RUN set -eux \
    && apk add --no-cache imagemagick imagemagick-libs \
    && apk add --no-cache --virtual .imagick-deps $PHPIZE_DEPS imagemagick-dev \
    && pecl install imagick \
    && docker-php-ext-enable imagick \
    && apk del .imagick-deps \
    && rm -rf /tmp/* /var/cache/apk/*

# Harden the policy file (path may be /etc/ImageMagick-7/policy.xml on Alpine)
COPY policy.xml /etc/ImageMagick-7/policy.xml
USER www-data
```

A hardened `policy.xml` should at minimum deny the `MSL`, `MVG`, `URL`, `HTTPS`,
`EPHEMERAL`, `LABEL`, and `@*` coders and set sane memory/disk limits. See the
[ImageMagick security policy docs](https://imagemagick.org/script/security-policy.php).

### Healthcheck

The base already declares a `HEALTHCHECK` using `php-fpm-healthcheck`, which queries
the FPM status page. To use it you must enable the FPM `pm.status_path` in your pool
config (e.g. `pm.status_path = /status`); otherwise override/disable the healthcheck
in your orchestrator.

---

## Architecture

Images are published for **`linux/amd64` only**. arm64 was dropped because cross-building
under QEMU emulation pushed CI from ~5 min to ~30 min, and all current consumers
(dev + prod) run on x86_64. Multi-arch can be reintroduced later (native ARM runners or
a parallel build-matrix + manifest merge) if a consumer needs it.

---

## Security

- `apk upgrade --no-cache` runs at the top of the first build layer so inherited
  transitive packages (libxml2, nghttp2, musl, openssl, …) get the latest Alpine
  patches even when the upstream PHP base lags.
- Version pins (`~MAJOR.MINOR`) act as a stability contract within an Alpine branch;
  `apk upgrade` provides freshness inside it.
- CI runs **Trivy** (`ignore-unfixed: true`) on every build and **fails** on any fixable
  CRITICAL/HIGH. Results are published to the GitHub Step Summary and uploaded as
  artifacts.
- Runs as non-root (`www-data`).

---

## Building locally

```bash
docker build -t akyrahub/php:dev .
docker run --rm akyrahub/php:dev php -v
docker run --rm akyrahub/php:dev php -m   # list compiled-in modules
```

Always build and smoke-test locally before pushing — an extension that became built-in
upstream (e.g. `opcache` in PHP 8.5) can fail the build silently.

---

## License

MIT. Maintained by Hochi.