# Leftovers

Unfinished work from the session of 2026-09-17.

## Tasks

- [ ] 1. Close tasks 7 to 13 in checklist_mvp.md
- [ ] 2. Finish the script comment reformat
- [ ] 3. Verify the half-reformatted scripts

## 1. Close tasks 7 to 13 in checklist_mvp.md

The VM work moved to `checklist_vm.md`, which is written. Tasks 7 to 13
are still open in `checklist_mvp.md` and need closing with a pointer
there, so they are not tracked in two places.

## 2. Finish the script comment reformat

House style: one-line summary, blank `#`, then the reasoning. Applies to
the 26 `.sh` and `.yaml` files in `scripts/`, excluding the two `wip_`
files. Three agents started this and all died on a rate limit partway,
so some files are done and some are untouched. Tracked as task 21 in
`checklist_mvp.md`.

## 3. Verify the half-reformatted scripts

Nothing was syntax-checked after the agents died. Confirm every `.sh`
still parses, both `.yaml` files still load, no executable line changed,
and the heredoc bodies in `dev_5`, `dev_6` and `util_measure.sh` are
byte-identical, since their contents run inside the probe pod.
