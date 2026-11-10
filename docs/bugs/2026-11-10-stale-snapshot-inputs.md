# Nothing to change in the pin files

**Status:** open  
**Started:** 2026-11-10

## Fix

No change in this repository. The published files stay as they are.

The change is in `pixie-pkg prove`, the command already planned for the GTK tag. That command downloads the published libraries and compiles GTK. It does not look up a newer fontconfig main, and it does not compare recipe hashes. If either of those checks runs, the tag build tries to compile fontconfig, libepoxy, and graphene, which are already published.

## What happened

The tag script cloned this repo and ran `scripts/prove-package.sh`. That script looks the libraries up again. Fontconfig is recorded as `main` from the daily check (commit `548591665a8e` on release `1.261109`), so a fresh lookup can be a newer commit. libepoxy and graphene are recorded as commits, and the recipe hash includes the checkout path, so the same files do not match in the tag job's clone. Either miss makes prove compile the library.

The dry run skips the lookup, which is why it said download and the real run said compile.
