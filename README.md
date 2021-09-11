# micro-acme

An [acme](http://acme.cat-v.org/) style editing plugin for the [micro](https://micro-editor.github.io/) editor.

This plugin enhances micro with 4 commands:

* `e` executes a CLI program, then create a new buffer containing data written to stdout/stderr. Example: `> e rg -n micro`
* `|`, `<` and `>` provides acme style editing, see [this video](http://research.swtch.com/acme) for an example. Notice due to how micro's command works, you need to add an extra space, for example: `> spell`, `| rot13`, etc.

This plugin also provides a `search` command, that does acme style searching(tho the function is not yet complete), I typically bind it to `MouseRight`.
