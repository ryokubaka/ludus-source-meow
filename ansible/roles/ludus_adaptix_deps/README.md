# ludus_adaptix_deps (1.0.2)

Install the Qt 6 packages Adaptix C2’s **client** build needs on Kali, then expose private Gui headers at the include path KDDockWidgets expects.

Run this **before** [`badsectorlabs.ludus_adaptix_c2`](https://github.com/badsectorlabs/ludus_adaptix_c2).

## Why this role exists

Adaptix v1.2’s client pulls in **Qt6 Svg**, **Qt6 Qml/Declarative**, and KDDockWidgets code that does:

```cpp
#include <QtGui/private/qtx11extras_p.h>
```

The upstream Adaptix Ludus role installs generic build deps but not those Qt modules. On Debian/Kali, `qt6-base-private-dev` places private headers under:

```text
/usr/include/<multiarch>/qt6/QtGui/<version>/QtGui/private/
```

while the include wants `QtGui/private/...`. Without a symlink (or a GuiPrivate cmake link the Adaptix tree does not set up), `make client` dies after qlementine builds.

## What it does

1. `apt` install `ludus_adaptix_deps_packages` (update cache)
2. Discover the directory that contains `qtx11extras_p.h`
3. Symlink that directory to `/usr/include/<multiarch>/qt6/QtGui/private` when it is not already the unversioned path
4. Mark `/opt/adaptix` and `/opt/adaptix/Extension-Kit` as git `safe.directory` for root and `ansible_user`
5. If `/opt/adaptix` already exists, ensure `Extension-Kit` is owned by `ansible_user` so the upstream role’s non-`become` clone/update does not fail with “dubious ownership” after the tree was `chown`’d to `adaptix`

## Blueprint usage

```yaml
roles:
  - name: ryokubaka.ludus_adaptix_deps
  - name: badsectorlabs.ludus_adaptix_c2
  - name: ryokubaka.ludus_adaptix_c2_fix
role_vars:
  ludus_adaptix_c2_install_server: true
  ludus_adaptix_c2_install_client: true
  ludus_adaptix_c2_version: v1.2
  ludus_adaptix_c2_go_version: "1.25.4"
```

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_adaptix_deps_packages` | `qt6-svg-dev`, `qt6-declarative-dev`, `qt6-base-private-dev` | Apt packages to ensure present |
| `ludus_adaptix_git_safe_directories` | `/opt/adaptix`, `/opt/adaptix/Extension-Kit` | Paths added to git `safe.directory` before upstream clone |

## Notes

- Server build needs **Go 1.25.4+** for Adaptix v1.2 (`go.mod`); that is a `ludus_adaptix_c2_go_version` pin on the upstream role, not this package list.
- Idempotent: re-running only ensures packages and the symlink.
- Pair with [`ludus_adaptix_c2_fix`](../ludus_adaptix_c2_fix/) so the teamserver profile/unit match v1.2 after the upstream role finishes.
