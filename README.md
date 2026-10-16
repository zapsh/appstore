# ZAP App Store Packages

This repository is the **package source** for the [zap](https://github.com/zapsh/zap) application
store. Each subdirectory under a category folder is one installable package. The zap panel reads
the package manifests and scripts from here, presents them in the store UI, and runs the install
/ upgrade / uninstall scripts on the target host.

Packages are grouped by category:

| Category     | Purpose                                                        |
| ------------ | -------------------------------------------------------------- |
| `application`| Language tooling and CLIs (PHP, Composer, PIE, WP-CLI)         |
| `database`   | Databases (MySQL / MariaDB) , PostgreSQL                       |
| `infra`      | System infrastructure services (Nginx, Docker)                 |
| `library`    | Shared native libraries (OpenSSL, libpcre2)                    |
| `plugins`    | Panel plugins distributed through the store                    |
| `tools`      | Web-based admin tools (phpMyAdmin)                             |
| `webapps`    | Site applications installed into a user site (WordPress, skeleton) |

## Included packages

| Path                      | Title                          | Notes                                  |
| ------------------------- | ------------------------------ | -------------------------------------- |
| `application/composer`    | Composer                       | PHP dependency manager                 |
| `application/php`         | PHP                            | FPM runtime, runtime versions          |
| `application/pie`         | PIE (PHP Installer for Extensions) | PHP extension installer            |
| `application/wpcli`       | WP-CLI                         | WordPress command line                 |
| `database/mysql`          | MySQL / MariaDB                | Database server                        |
| `infra/docker`            | Docker                         | Container runtime (docker / podman)    |
| `infra/nginx`             | Nginx                          | Web server / reverse proxy (with WAF)  |
| `library/libpcre2`        | libpcre2                       | PCRE2 library                          |
| `library/openssl`         | OpenSSL                        | TLS / SSL toolkit                      |
| `plugins/composer-create` | 创建 Composer 项目             | Panel plugin (with `manifest.yaml`)    |
| `plugins/git`             | Git 管理                       | Panel plugin (with `manifest.yaml`)    |
| `plugins/hello-plugin`    | 目录体检（示例插件）           | Example panel plugin                   |
| `plugins/widgets-demo`    | 控件示例（示例插件）           | Example panel plugin                   |
| `tools/phpmyadmin`        | phpMyAdmin                     | Web DB admin tool                      |
| `webapps/skeleton`        | Web 应用骨架                   | Blank site scaffold                    |
| `webapps/wordpress`       | WordPress                      | Site app, panel-provisioned site + DB  |


## Package layout

Each package directory contains:

```
<category>/<name>/
├── app.yaml          # store metadata + install constraints (required)
├── install.sh        # install script (bash) — or install.py, see scripts:
├── uninstall.sh      # uninstall script (optional)
├── upgrade.sh        # upgrade script (optional)
├── icon.png          # package icon (referenced by app.yaml: icon)
└── manifest.yaml      # (plugins only) runtime manifest for the plugin itself
```

The script filename is **not** fixed — it is declared in `app.yaml` under `scripts:`. The panel
copies the whole package into an isolated `runs/<run_id>/pkg` snapshot, executes the declared
script, and on success records `info.yaml` at the install path so the panel can later discover,
start, stop, and uninstall the instance.

## Manifest (`app.yaml`)

A minimal manifest:

```yaml
name: nginx
title: Nginx
version: [1.31.5]
license: Apache-2.0
homepage: https://nginx.org
platforms:
  - linux/amd64
  - linux/arm64
category: infra
description: HTTP web server, reverse proxy, load balancer, and mail proxy server.
icon: nginx.png
allow_multiple_instances: 'no'
tags: [webserver]
author: zap
organization_name: zap
scripts:
  install: install.sh
options:
  install:
    - name: OPENSSL_VERSION
      label: OpenSSL Version
      type: select
      default: 3.5.6
      choices:
        - { label: 3.5.6, value: 3.5.6 }
        - { label: 3.6.3, value: 3.6.3 }
```

### Common fields

| Field                    | Description                                                                 |
| ----------------------- | --------------------------------------------------------------------------- |
| `name`                  | Machine name (unique within the store).                                     |
| `title`                 | Human-readable name shown on the card.                                      |
| `version`               | Array of available versions. The **first** entry is the default.           |
| `license` / `homepage`  | Upstream license and project URL (display only).                            |
| `platforms`             | Supported platforms, e.g. `linux/amd64`, `linux/arm64`.                     |
| `category`              | One of the top-level folders above.                                         |
| `description`           | Short summary shown on the card.                                            |
| `icon`                  | Icon filename in the package directory.                                     |
| `tags`                  | Search / grouping tags.                                                     |
| `allow_multiple_instances` | `'yes'` to allow several instances (e.g. multiple PHP versions) at once. |
| `scope` / `run_as`      | `site` + `user` = installed into a user site and run as that site's Linux account (no login). |
| `roles`                 | Which roles may see / install the package. Omit = admin only.               |
| `dependencies`         | Soft dependency declaration, e.g. `php: '>=7.4'`.                           |
| `scripts`               | Map of `install` / `upgrade` / `uninstall` to script filenames.             |
| `options`               | Per-action option forms (see below).                                        |
| `provision`             | Panel-side orchestration for site apps (see below).                         |

### Options (`options.<action>`)

Each install / upgrade / uninstall action may declare an option form. An `intro` string is shown
at the top of the dialog; `items` is a list of fields:

| Item field | Meaning                                                                     |
| ---------- | --------------------------------------------------------------------------- |
| `name`     | Env var name injected into the script.                                      |
| `label`    | Label shown in the form.                                                    |
| `type`     | `string` \| `number` \| `bool` \| `select` \| `multiselect`.               |
| `default`  | Default value.                                                              |
| `required` | Whether the field is required.                                              |
| `choices`  | Options for `select` / `multiselect`.                                       |
| `desc`     | Helper text under the field.                                               |

Options are passed to the script verbatim as environment variables with the same name (booleans
become `"true"` / `"false"`, multiselect is joined by a separator).

### Provisioning (`provision`)

Site-class packages (`scope: site`) cannot create sites or databases themselves — that requires
privileges the (de-privileged) script should not have. Instead, the panel prepares the site and a
dedicated database **before** the task is queued, then injects the connection details through the
environment (`SITE_ID`, `SITE_DOMAIN`, `SITE_ROOT`, `SITE_OWNER`, `SITE_LINUX_USER`,
`PHP_INSTANCE`, `PHP_FPM_SOCK`, `DB_NAME`, `DB_USER`, `DB_PASS`, `DB_HOST`, `DB_PORT`,
`DB_CHARSET`, `DB_USER_HOST`). Database passwords are **never** written to `options.env` /
`info.yaml`; they live only in the script process and `provision.json` (`0600`).

```yaml
provision:
  site:
    mode: create            # create the site if missing
    domain_option: SITE_DOMAIN
    rewrite: wordpress
  database:
    name: wp
    charset: utf8mb4
```

## Script contract

- Scripts run from a copy of the package snapshot; the install path / instance directory is given
  via `APP_PATH` (and `APPS_DIR`).
- The panel injects standard env vars (`ZAP_PATH`, `APPS_DIR`, `PKG_PATH`, `APP_PATH`,
  `APP_VERSION`, `BUILD_PATH`, `CPU_NUM`, …) plus any `options` and `provision` values.
- `install` is idempotent where possible: zap's upgrade flow is "uninstall first, then install",
  so re-running an install script is safe.
- On success the script writes `info.yaml` (service name, config file(s), pid file, exposed port,
  data root, …) at `APP_PATH` so the panel can manage the instance.

## Contributing

1. Create a new folder under the appropriate category: `<category>/<name>/`.
2. Add `app.yaml` with `name`, `category`, `version`, `scripts`, and metadata.
3. Implement the declared `install` script (and `upgrade` / `uninstall` if applicable).
4. For panel plugins, also add `manifest.yaml` describing how the plugin runs.
5. Test install / upgrade / uninstall on a real host, then open a pull request.

## License

See [LICENSE](./LICENSE). Individual packages may carry their own upstream license, declared in
each `app.yaml` (`license` field).
