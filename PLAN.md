# Working state

Branch: `bug-sweep` (off `main` at 48cdf79). No PR yet.

## What this is

Fixing the 38 open issues on AbhinavMir/soquel, found by an adversarial bug
sweep. Order is data loss first, then wrong result, then UI.

Labels: `data loss`, `Wrong Result`, `UI`. Nothing else.

## Done

- **#6 #7 #8 #9 #21 #22 #38 — theme cluster** — commit `c6fa729`.
  ThemeConfig test-path redirect; writeTemplate keeps resolved colours and the
  background; theme filename collisions no longer overwrite; apply() sets the
  image path when a theme has no background block; capture() never ships the
  author's path; theme.json is the single source of truth and the stored theme
  name is only a label.
  498 tests pass, up from 487.

## Next

Data loss, remaining:
- **#10** sync of a type-conflict entry replaces a directory with a file
- **#11** merge Replace branch recursively deletes the destination folder
- **#12** stage-then-swap deletes the destination before the swap

Then Wrong Result (#13–#20, #23–#30), then UI (#31–#41).

Unlabelled feature issues #3 #4 #5 are out of scope for this sweep.

## Decisions taken

- **`.soquel-theme` files stay.** The overlap with theme.json (#22) is resolved
  by making theme.json the live state; a theme file is a preset that writes
  into it. The stored name no longer overrides the file at launch.
- Watch for `?? .none` in an optional context — Swift reads it as
  `Optional.none`, so it silently does nothing. That mistake was the cause of
  #21 and I reintroduced it in the first attempt at the fix.

## Environment notes

- The user's real theme is pink with a sakura background, set by hand in
  `~/Library/Application Support/Soquel/theme.json`. Do not let tests or
  fixtures write to that file — verify its md5 is unchanged after any test run.
  Backup: scratchpad `theme.json.backup`.
