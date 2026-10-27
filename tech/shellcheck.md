# ShellCheck

## 1. What it is

ShellCheck reads shell scripts without running them and warns about bugs: unquoted variables, wrong tests, unreachable code, commands that behave differently than they look.

## 2. Why this repository uses it

There are about 26 scripts. ShellCheck finds quoting and logic mistakes in them before they run against a cluster.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `.shellcheckrc` | options |
| `Makefile (`SCRIPTS`, `lint`)` | `shellcheck $(SCRIPTS)` |
| `scripts/**/*.sh, docker/git-server/entrypoint.sh` | what is checked |
| `scripts/lib.sh, provider.sh` | `# shellcheck shell=bash` and `# shellcheck source=` comments |

## 4. How it works underneath

- Each finding has a code such as `SC2086` (unquoted variable). `# shellcheck disable=SC2086` above a line switches one off.
- `# shellcheck source=file` tells it which file a `source` line loads so it can check variables defined there.
- `.shellcheckrc` holds options: `external-sources=true` lets it follow `source`; `source-path=SCRIPTDIR` resolves paths relative to the script.
- `# shellcheck shell=bash` states the dialect for a file without a shebang (a library meant to be sourced).

## 5. Walkthrough of this repository's use

```
external-sources=true
source-path=SCRIPTDIR
```
`external-sources=true` lets ShellCheck read files named in `source`. `source-path=SCRIPTDIR` resolves a relative `source` from the script's own folder. In the scripts, `# shellcheck source=../versions.env` (above a `source` line) names the file for that one line, and `# shellcheck source=/dev/null` says "do not follow this one" for `.env`, which may not exist. Libraries meant to be sourced start with `# shellcheck shell=bash` because they have no shebang. In the Makefile, `$(wildcard ...)` builds the file list so a new script is checked automatically.

## 6. Try it yourself

1. `shellcheck scripts/lib.sh` : no output.
2. Make a copy with `rm -rf $dir/` (unquoted, no default) : a warning with a code.
3. `shellcheck -f gcc scripts/up.sh` : one-line findings.
4. `shellcheck --version` : the version.
5. `make lint 2>&1 | grep -i shellcheck` : the command as the Makefile runs it.

## 7. Mistakes people make

- Disabling warnings in bulk. A disable here always names a single code with a reason.
- Not telling ShellCheck about sourced files, which makes it report variables as unset.

## 8. Check yourself

1. Does ShellCheck run the script?
   *Answer:* No; it analyses the text.
2. What does `SC2086` warn about?
   *Answer:* A variable used without quotes.
3. What does `external-sources=true` allow?
   *Answer:* Following `source` lines into other files.
4. Why does `lib.sh` have `# shellcheck shell=bash`?
   *Answer:* It has no shebang, so the dialect must be stated.
5. How do you silence one warning on one line?
   *Answer:* A `# shellcheck disable=SCxxxx` comment above it.

## 9. Further reading

- ShellCheck wiki with every code: <https://www.shellcheck.net/wiki/>.
