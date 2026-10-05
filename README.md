# Bash: Darwin locale restoration after fork

A function-local `LC_ALL=C` is restored from a nested pipeline child. On the observed native non-interactive Bash build, locale restoration enters gettext/CoreFoundation and can SIGSEGV. This reproduction retains the canonical framing/validation sequence that triggers it; reducing it to a bare locale assignment did not reproduce.

## Reproduce

On Apple Silicon macOS with Nix:

```sh
nix shell github:NixOS/nixpkgs/4ba99f3209788ed04f01af38f77ddb803ad6ec63#bash github:NixOS/nixpkgs/4ba99f3209788ed04f01af38f77ddb803ad6ec63#coreutils github:NixOS/nixpkgs/4ba99f3209788ed04f01af38f77ddb803ad6ec63#libiconv --command bash ./repro.sh
```

The script uses only Bash, SHA-256, sort and iconv. `HASH_BIN`, `SORT_BIN` and `ICONV_BIN` may select explicit tool paths. It runs 200 synthetic canonical-identity derivations and checks every exact result.

## Expected and observed

Expected: `passed 200 exact identities`, exit 0.

Observed native non-interactive build: `FAILED iteration=0`, exit 1; the digest writer's pipeline status was `139 0` (Bash writer SIGSEGV, SHA-256 consumer success).

Counter-experiment, same binary and script:

```sh
LC_ALL=C bash ./repro.sh
```

Observed: 200/200 exact identities, exit 0.

Observed Linux x86_64 Bash 5.3.15: 200/200 exact identities. Observed native `bashInteractive` 5.3p15, invoked non-interactively: 200/200.

## Versions and build differences

- macOS 27.0.1 (26A434), arm64.
- Nixpkgs `4ba99f3209788ed04f01af38f77ddb803ad6ec63`.
- Both Bash builds are 5.3p15, use `--without-bash-malloc`, and contain the same Bash patches 001–015 plus `pgrp-pipe-5.patch`.
- Plain build: `--disable-readline`, bootstrap-stage2 Darwin stdenv.
- Interactive build: `--with-installed-readline`, normal Darwin stdenv. No interactive flag is used in the counter-experiment.

## Crash stack (sanitized)

```text
_os_log_preferences_refresh
os_log_type_enabled
CFPrefsSearchListSource alreadylocked_copyValueForKey
CFPreferencesCopyAppValueWithContainerAndConfiguration
LocaleCache.preferredLanguages
CFLocaleCopyPreferredLanguages
libintl_setlocale
reset_locale_vars
set_locale_var
sv_locale
push_posix_tempvar_internal
pop_var_context
pop_context
execute_function
execute_in_subshell
command_substitute
```

The diagnostic marks the crash as `EXC_BAD_ACCESS / SIGSEGV`, `single-threaded process forked`, and `crashed on child side of fork pre-exec`.

No claim is made that the two Bash builds' readline difference is causal. The observed failure path is locale restoration in the forked child.
