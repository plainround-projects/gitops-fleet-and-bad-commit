# EditorConfig

## 1. What it is

EditorConfig is a tiny settings file (`.editorconfig`) that tells editors how to write files: indent with spaces or tabs, how wide, which line endings, whether to end with a newline.

## 2. Why this repository uses it

Contributors on different editors produce the same files: LF line endings, a final newline, spaces (tabs in the Makefile).

## 3. Where it appears

| File | What it does with this technology |
| --- | --- |
| `.editorconfig` | the rules |

## 4. How it works underneath

- Sections are file patterns in brackets (`[*.{yml,yaml}]`). Keys such as `indent_style`, `indent_size`, `end_of_line`, `insert_final_newline` and `trim_trailing_whitespace` apply to matching files.
- `root = true` stops the editor from looking in parent folders for more rules.
- Editors apply it as you type. It does not check files that were already saved wrongly.

## 5. Walkthrough of this repository's use

```ini
root = true
[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 4
[*.{yml,yaml,json,toml}]
indent_size = 2
[Makefile]
indent_style = tab
[*.md]
trim_trailing_whitespace = false
```
`[*]` applies to every file: UTF-8, Unix line endings (`lf`, not Windows `crlf`), a newline at the end, no trailing spaces, four-space indents. The next section narrows YAML, JSON and TOML to two spaces. `[Makefile]` requires tabs. Markdown keeps trailing spaces because two of them make a line break.

## 6. Try it yourself

1. `cat .editorconfig` : the rules.
2. `file scripts/up.sh` : ASCII text, with no `CRLF` mentioned.
3. `grep -c $'\t' Makefile` : tabs in the Makefile are expected.
4. `grep -rn ' $' scripts | head -3` : trailing spaces (none expected).
5. Open the repository in an editor with EditorConfig support and press Tab in a `.yaml` file : two spaces.

## 7. Mistakes people make

- Expecting it to fix existing files.
- Spaces in a Makefile, which needs tabs (a section sets `indent_style = tab` for it).

## 8. Check yourself

1. What does `root = true` mean?
   *Answer:* Stop searching parent folders for more settings.
2. Why does `[Makefile]` set tabs?
   *Answer:* Make requires a tab to start a recipe line.
3. Why is trailing whitespace allowed in `*.md`?
   *Answer:* Two trailing spaces mean a line break in Markdown.
4. Does EditorConfig change files that are already saved?
   *Answer:* No, it only guides the editor while you type.
5. What does `charset = utf-8` do?
   *Answer:* Files are saved as UTF-8 text.

## 9. Further reading

- EditorConfig: <https://editorconfig.org/>.
