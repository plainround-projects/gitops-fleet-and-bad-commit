# YAML

## 1. What it is

YAML is a plain-text format for structured data: lists, key-value maps and values. Most tools of this repository (Kubernetes, Kustomize, Argo CD, GitHub Actions, yamllint) read their configuration from YAML files.

## 2. Why this repository uses it

The fleet is declared in YAML at two levels: the ApplicationSets that generate Applications, and small per-stage data files (`clusters/<stage>.yaml`) that the generator reads as input.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `manifests/clusters/{dev,staging,production}.yaml` | plain data: stage, revision, prune, observeSeconds, syncWindow |
| `manifests/hub/*.yaml` | ApplicationSets and AppProjects |
| `manifests/policy/no-privileged.yaml` | the admission policy |
| `manifests/apps/web/base/*.yaml` | the application |
| `platform/**/*.yaml` | Argo CD install patch, Git server, cluster access, root Application |
| `.github/workflows/ci.yml, .yamllint.yaml` | workflow and linter |

## 4. How it works underneath

- **Indentation is structure.** Two spaces deeper means "inside". Tabs are not allowed.
- A **map** is `key: value`. A **list** item starts with `- `. They nest: a list of maps is very common.
- Scalars (single values) are strings, numbers, `true`/`false` and `null`. `"1"` in quotes is a string; `1` is a number. Kubernetes cares: `replicas: "many"` is refused because replicas must be a number.
- `---` starts a new **document** inside one file; Kubernetes files can hold several objects separated by it.
- `|` starts a **block scalar**: the following indented lines are one multi-line string. `{}` is an empty map; `["ALL"]` is a one-line list.
- `# text` is a comment.
- YAML 1.1 reads bare `yes`, `no`, `on`, `off` as booleans. That surprise is called "the Norway problem" (`no` is Norway's country code). Quote them.

## 5. Walkthrough of this repository's use

`manifests/clusters/production.yaml` is YAML used as a **data file**, not a Kubernetes object:

```yaml
---
stage: production
revision: main
# Production never prunes: a deleted file is flagged, not deleted.
prune: false
observeSeconds: 0
syncWindow: "22:00-23:00 UTC"
```
* No `apiVersion` or `kind`: the ApplicationSet's Git generator reads the keys as **template parameters** (`{{ .revision }}`, `{{ .prune }}`).
* `prune: false` is a **boolean**; `observeSeconds: 0` is a **number**; the sync window is a **string** in quotes (it contains a colon). `scripts/check_clusters.py` checks these types: a quoted `"false"` would be a string, and the template would produce wrong YAML.
* Comments (`#`) explain intent.

The ApplicationSet uses YAML in three ways: **flow style** maps (`{ group: "", kind: Namespace }`), a `templatePatch: |` **block scalar** that holds YAML text containing template expressions (`prune: {{ .prune }}` is not valid YAML until the template is rendered, which is why it is inside a string), and **anchors of text** inside quoted strings (`"web-{{ .name }}"`; quotes are needed because `{` starts a flow map in YAML).

## 6. Try it yourself

1. `.venv/bin/python scripts/check_clusters.py manifests` : exit status 0.
2. Set `prune: "false"` (quoted) in a copy and rerun : `production: prune must be true or false`.
3. `.venv/bin/yamllint -s .` : no output.
4. `.venv/bin/python -c "import yaml; print(yaml.safe_load(open('manifests/clusters/dev.yaml')))"` : the dict.
5. `grep -n 'templatePatch' -A8 manifests/hub/appset-web.yaml` : the block scalar.

## 7. Mistakes people make

- Wrong indentation moves a key to a different parent without any error.
- Unquoted values that look like something else: `1.10` becomes the number 1.1, `on` becomes true.
- Duplicate keys: the last one silently wins in some parsers. `yamllint` catches it.
- Mixing tabs and spaces. This repository's `.editorconfig` and `yamllint` forbid tabs.

## 8. Check yourself

1. How does YAML show that one key is inside another?
   *Answer:* By deeper indentation with spaces.
2. What is the difference between `1` and `"1"`?
   *Answer:* A number and a string. Kubernetes fields have fixed types.
3. What does `---` do?
   *Answer:* It starts a new document in the same file.
4. What does `|` start?
   *Answer:* A block scalar: the indented lines below are one multi-line string.
5. Why quote `no` or `on`?
   *Answer:* YAML 1.1 parsers read them as booleans.

## 9. Further reading

- YAML 1.2.2 specification: <https://yaml.org/spec/1.2.2/>. Kubernetes reads YAML 1.1-style booleans in some paths, so quote ambiguous words.
