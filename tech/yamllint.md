# yamllint

## 1. What it is

yamllint checks YAML files for syntax errors and for style problems such as bad indentation, duplicate keys, too-long lines and trailing spaces.

## 2. Why this repository uses it

Style errors (indentation, duplicate keys, long lines) are caught before Kubernetes or CI sees the file.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `.yamllint.yaml` | the rules |
| `Makefile (`lint`)` | `yamllint -s .` |
| `all *.yaml and *.yml` | the manifests, hub objects, policy and workflow |

## 4. How it works underneath

- It starts from a rule set (`extends: default`) and the `.yamllint.yaml` file overrides rules.
- `-s` (strict) turns warnings into failures. `ignore:` lists paths to skip.
- Each rule has options, for example `line-length: max: 140` and `document-start: present: true` (every file starts with `---`).

## 5. Walkthrough of this repository's use

```yaml
extends: default
ignore: |
  .venv/
  .work/
rules:
  line-length: { max: 140 }
  document-start: { present: true }
  truthy: { allowed-values: ["true", "false"], check-keys: false }
  comments: { min-spaces-from-content: 2 }
  braces: { min-spaces-inside: 0, max-spaces-inside: 1 }
  brackets: { min-spaces-inside: 0, max-spaces-inside: 1 }
```
(The file writes each rule over several lines.) `ignore:` is a block of paths. `line-length` 140 allows long commands in the workflow. `document-start` requires `---`. `truthy` allows only `true` and `false`, so YAML 1.1 words like `yes`/`on` are errors, and `check-keys: false` lets GitHub Actions' key `on:` pass. `comments` wants two spaces before `# text` that follows a value. `braces` and `brackets` allow one space inside `{ }` and `[ ]` (`target: { kind: Deployment }`) or none (`{}`).

<!-- full-walkthrough:begin -->
### 5.A Full walkthrough: the whole `.yamllint.yaml`

```yaml
---
extends: default
ignore: |
  .venv/
  .work/
rules:
  line-length:
    max: 140
  document-start:
    present: true
  truthy:
    allowed-values: ["true", "false"]
    check-keys: false
  comments:
    min-spaces-from-content: 2
  braces:
    min-spaces-inside: 0
    max-spaces-inside: 1
  brackets:
    min-spaces-inside: 0
    max-spaces-inside: 1
```

- `---` starts the YAML document (required at the top of every YAML file here). `extends: default` begins from yamllint's built-in rules. `ignore: |` is a block of text (the `|` keeps line breaks) listing folders to skip: the virtual environment and the working clone.
- `line-length: max: 140` allows long lines (the manifests contain long image names and JSONPath expressions). `document-start: present: true` demands `---`. `truthy: allowed-values: ["true", "false"]` accepts only those words as booleans (YAML 1.1 also reads `yes`/`no`/`on`/`off` as booleans, which surprises people); `check-keys: false` skips key names (GitHub Actions has a key `on`). `comments: min-spaces-from-content: 2` wants two spaces before a `#` that follows content. `braces` and `brackets` allow zero or one space inside `{}` and `[]` (the projects use `{ server: "*", namespace: web }`).
<!-- full-walkthrough:end -->

## 6. Try it yourself

1. `.venv/bin/yamllint -s .` : no output.
2. Delete `---` from a copy of a manifest and lint it : `missing document start "---"`.
3. Put a tab in a YAML file : a syntax error.
4. `.venv/bin/yamllint -f parsable .github/workflows/ci.yml` : machine-readable format.
5. `.venv/bin/yamllint --version` : `yamllint 1.38.0`.

## 7. Mistakes people make

- Turning rules off instead of fixing the file.
- Forgetting the `---` line at the top when the config requires it.

## 8. Check yourself

1. What does `extends: default` mean?
   *Answer:* Start from yamllint's built-in rules, then apply the overrides below.
2. What does `-s` change?
   *Answer:* Warnings also make the command fail.
3. What is `document-start: present: true` for?
   *Answer:* It requires every file to begin with `---`.
4. What does `ignore:` do?
   *Answer:* Skips the listed paths (such as the virtual environment).
5. Does yamllint know Kubernetes?
   *Answer:* No. It checks YAML style only; kubeconform checks Kubernetes meaning.

## 9. Further reading

- yamllint: <https://yamllint.readthedocs.io/en/stable/> (pinned 1.38.0).
