# grep, sed, curl, base64, tr and other command-line tools

## 1. What it is

Unix tools are small programs that each do one text or network job and are joined with pipes. This note covers the ones this repository calls: `grep`, `sed`, `perl`, `curl`, `base64`, `tr`, `cut`, `head`, `wc`, `date`, `kill`.

## 2. Why this repository uses it

The scripts read values out of YAML files, edit them, call the running app, decode tokens and count results.

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `scripts/lib.sh (`stage_value`, `set_stage_value`, `web_get`)` | grep, sed and perl on the stage files; curl on the app |
| `scripts/best-case.sh` | `grep -oE` pulls numbers out of YAML |
| `scripts/register-cluster.sh` | `base64 -d` decodes the token |
| `scripts/runbook/window.sh` | `date -u +%H`, `perl -pi -e`, `printf` |
| `scripts/runbook/06-controller-outage.sh` | `curl -w`, `kill`, `wc -l`, `grep -vc` |
| `scripts/runbook/05-destructive-commit.sh` | `perl -ni -e`, `wc -l | tr -d ' '` |

## 4. How it works underneath

- `grep -oE 'pattern'` prints only the matching part using an extended regular expression; `grep -vc` counts lines that do **not** match.
- `sed -E 's/^key:[[:space:]]*//'` deletes a key and the spaces after it (`[[:space:]]` is a character class for whitespace).
- `base64 -d` decodes base64 text; Kubernetes stores Secret values in base64.
- `curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 URL` prints only the HTTP status code (`-s` silent, `-o /dev/null` discard the body, `-w` a format, `--max-time` a time limit).
- `date -u +%H` prints the current UTC hour. A value like `08` read by Bash arithmetic is octal and fails; `10#08` forces base 10.
- `kill <pid>` sends a signal (TERM by default); `$!` is the pid of the last background job.
- `wc -l < file` counts lines; the redirect avoids printing the file name.

## 5. Walkthrough of this repository's use

```bash
requeue="$(grep -oE 'requeueAfterSeconds: [0-9]+' manifests/hub/appset-web.yaml | grep -oE '[0-9]+')"
poll="$(grep -oE 'timeout.reconciliation: [0-9]+s' platform/argocd/controller-settings.yaml | grep -oE '[0-9]+')"
dev_observe="$(grep -E '^observeSeconds:' manifests/clusters/dev.yaml | grep -oE '[0-9]+')"
total=$((poll + dev_observe + requeue + staging_observe + requeue))
```
`best-case.sh` reads each number out of the file that actually configures it, so the arithmetic cannot drift from the configuration: the first `grep -oE` finds the setting, the second extracts the digits. `$(( ))` adds them. With the configured values this gives 20 + 30 + 20 + 45 + 20 = 135 seconds.

```bash
perl -pi -e "s/schedule: \"0 \d+ \* \* \*\"/schedule: \"0 ${start} * * *\"/" hub/projects.yaml
```
Replace the hour in the cron expression; `\d+` is one or more digits, `\*` a literal star. The double-quoted shell string lets `${start}` expand.

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "http://127.0.0.1:18103/healthz" >> "${log_file}" || echo 000 >> "${log_file}"
```
One status code per second appended to a log; a failed request records `000`. After the outage, `grep -vc '^200$' log` counts the lines that are not exactly `200`: the number of failed requests.

`web_get() { curl -fsS --max-time 3 "http://127.0.0.1:$(host_port_of "$1")$2"; }` calls an app through its published host port; `-f` makes an HTTP error a failure.

## 6. Try it yourself

1. `scripts/best-case.sh` : 135 s.
2. `grep -oE 'requeueAfterSeconds: [0-9]+' manifests/hub/appset-web.yaml` : `requeueAfterSeconds: 20`.
3. `echo c2VjcmV0 | base64 -d` : `secret`.
4. `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18101/healthz` (cluster up) : `200`.
5. `date -u +%H; echo $((10#08 + 1))` : the hour, and `9`.

## 7. Mistakes people make

- Reading numbers from a hand-copied constant. The scripts read them from the config files.
- Octal surprises in `08` and `09`; use `10#`.
- Counting failed requests with `grep` but forgetting that no failure gives exit status 1 (`|| true`).

## 8. Check yourself

1. What does `grep -o` print?
   *Answer:* Only the part of the line that matched.
2. What does `curl -w '%{http_code}'` print?
   *Answer:* The HTTP status code of the response.
3. Why `10#08`?
   *Answer:* Bash would read `08` as an invalid octal number.
4. What is `$!`?
   *Answer:* The process id of the most recent background command.
5. Why read numbers from the YAML files?
   *Answer:* So the arithmetic cannot disagree with the configuration.

## 9. Further reading

- GNU grep: <https://www.gnu.org/software/grep/manual/grep.html>. curl `--write-out`: <https://curl.se/docs/manpage.html#-w>. Bash arithmetic and bases: <https://www.gnu.org/software/bash/manual/bash.html#Shell-Arithmetic>.
