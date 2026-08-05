# Ludus Templates

Self-contained [Packer](https://packer.io/) templates for this source.
Each subdirectory builds one Ludus VM template. See
https://docs.ludus.cloud/docs/templates and
https://docs.ludus.cloud/docs/using-ludus/sources for authoring rules.

## Installing

```bash
ludus source add https://github.com/ryokubaka/ludus-source-meow.git
ludus templates build -n <template-name>
```

## Available templates

| Template | Description |
|---|---|
| _(none yet)_ | Add a dir under `templates/` with a `*.pkr.hcl` |

## Authoring checklist

1. Create `templates/<name>/`
2. Add `<name>.pkr.hcl` with `description` and `icon_path` variables
3. Linux: `http/` preseed or kickstart · Windows: `Autounattend.xml`
4. Document the `*-template` name in this README
5. After `source add`, build: `ludus templates build -n <name>`
