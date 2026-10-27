# PyYAML

## 1. What it is

PyYAML is a Python library that turns YAML text into Python dictionaries and lists (`yaml.safe_load`) and back.

## 2. Why this repository uses it

The stage-file checker and the manifest tests read YAML as data.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/check_clusters.py` | `yaml.safe_load` of each stage file, `yaml.safe_load_all` of the projects file |
| `tests/unit/` | tests reading the rendered base, hub objects and policy |
| `pyproject.toml, requirements.lock` | pinned at 6.0.3 |

## 4. How it works underneath

- `yaml.safe_load(text)` returns the first document as nested dicts and lists. `safe_load_all` yields one object per `---` document.
- `safe_` means it builds only plain data. The non-safe `yaml.load` can create arbitrary Python objects from a tag, which is a security risk with untrusted files.
- Numbers come back as `int`, quoted values as `str`, `true` as `True`.

## 5. Walkthrough of this repository's use

`yaml.safe_load(path.read_text())` turns a stage file into a dict: `{'stage': 'production', 'revision': 'main', 'prune': False, 'observeSeconds': 0, 'syncWindow': '22:00-23:00 UTC'}`. Types matter: `prune: false` becomes the Python boolean `False`; the sync window stays a string because it is quoted. `yaml.safe_load_all` reads `hub/projects.yaml`, which holds four documents separated by `---`, yielding a dict for each (an empty document would be `None`, hence `if p`). `safe_` loaders only build plain data and never run code from a file.

## 6. Try it yourself

1. `.venv/bin/python -c "import yaml; print(yaml.safe_load(open('manifests/clusters/production.yaml')))"` : the dict above.
2. `.venv/bin/python -c "import yaml; print([d['metadata']['name'] for d in yaml.safe_load_all(open('manifests/hub/projects.yaml'))])"` : `['dev', 'staging', 'production', 'fleet-policy']`.
3. `.venv/bin/pip show pyyaml | head -2`.
4. `.venv/bin/pytest tests/unit -q -k clusters` : stage-file tests.
5. `.venv/bin/python -c "import yaml; print(yaml.safe_load('a: 22:30'))"` : a number (sexagesimal in YAML 1.1: `1350`), a reason to quote times.

## 7. Mistakes people make

- Using `yaml.load` on files you did not write.
- Forgetting that `safe_load` reads only the first document of a multi-document file.
- Expecting YAML 1.2 rules: PyYAML follows YAML 1.1.

## 8. Check yourself

1. What is the difference between `safe_load` and `safe_load_all`?
   *Answer:* One reads the first document; the other yields every document.
2. Why prefer `safe_load` over `load`?
   *Answer:* It cannot build arbitrary Python objects from a file.
3. What does `no` become in PyYAML?
   *Answer:* `False`.
4. What type is a quoted `"1"`?
   *Answer:* A string.
5. Why do tests load YAML as data?
   *Answer:* To assert on facts without a cluster.

## 9. Further reading

- PyYAML: <https://pyyaml.org/wiki/PyYAMLDocumentation> (6.0.3).
