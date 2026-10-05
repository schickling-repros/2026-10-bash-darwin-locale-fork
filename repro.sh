#!/usr/bin/env bash
set -euo pipefail
    _u32be() {
      local n=$1 bytes
      printf -v bytes '\\%03o\\%03o\\%03o\\%03o' \
        "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" \
        "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
      printf '%b' "$bytes"
    }

    _frame() {
      local LC_ALL=C
      _u32be "${#1}"
      printf '%s' "$1"
    }

    _job_key_bytes() {
      local job=$1 dimension name value candidate
      shift
      _frame "$job"
      _u32be "$#"
      (( $# )) || return 0
      local -a names=()
      local -A seen=()
      for dimension in "$@"; do
        name="${dimension%%=*}"
        value="${dimension#*=}"
        [[ -n "$name" && -n "$value" && "$dimension" == *=* ]] ||
          { echo "otel-span: invalid matrix dimension" >&2; return 1; }
        [[ -z "${seen[$name]+x}" ]] ||
          { echo "otel-span: duplicate dimension name" >&2; return 1; }
        seen[$name]=1
        names+=("$name")
      done
      while IFS= read -r -d "" name; do
        for dimension in "$@"; do
          candidate="${dimension%%=*}"
          if [[ "$candidate" == "$name" ]]; then
            _frame "$name"
            _frame "${dimension#*=}"
            break
          fi
        done
      done < <(printf '%s\0' "${names[@]}" | LC_ALL=C ${SORT_BIN:-sort} -zu)
    }

    _derive_pipeline_id() {
      local domain=$1 length=$2 run=$3 counter=0 digest result
      shift 3
      while :; do
        digest="$(
          {
            printf '%s\0' "$domain"
            _frame "$run"
            if [[ "$domain" == buck2.job.* ]]; then _job_key_bytes "$@" || return 1; fi
            if (( counter > 0 )); then _u32be "$counter"; fi
          } | ${HASH_BIN:-sha256sum}
        )" || return 1
        result="${digest:0:length}"
        if [[ "$result" != "$(printf '%0*d' "$length" 0)" ]]; then
          printf '%s' "$result"
          return
        fi
        ((counter += 1))
      done
    }

    _valid_ci_component() {
      local component=$1 char hex byte i
      [[ -n "$component" ]] || return 1
      {
        for ((i = 0; i < ${#component}; i++)); do
          char="${component:i:1}"
          if [[ "$char" == "%" ]]; then
            hex="${component:i+1:2}"
            [[ "$hex" =~ ^[0-9A-F]{2}$ ]] || return 1
            byte=$((16#$hex))
            # Canonical RFC 3986 encoding leaves unreserved bytes literal.
            if (( (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
                  (byte >= 48 && byte <= 57) || byte == 45 || byte == 46 ||
                  byte == 95 || byte == 126 )); then return 1; fi
            printf '%b' "\\x$hex"
            ((i += 2))
          else
            [[ "$char" =~ ^[a-zA-Z0-9._~-]$ ]] || return 1
            printf '%s' "$char"
          fi
        done
      } | ${ICONV_BIN:-iconv} -f UTF-8 -t UTF-8 >/dev/null 2>&1
    }

    _valid_pipeline_run_id() {
      local id=$1 provider repo run attempt
      if [[ "$id" =~ ^local/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
        return 0
      fi
      if [[ "$id" =~ ^ci/([^/]+)/([^/]+)/([^/]+)/([1-9][0-9]*)$ ]]; then
        provider="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" run="${BASH_REMATCH[3]}" attempt="${BASH_REMATCH[4]}"
        local component
        for component in "$provider" "$repo" "$run"; do
          _valid_ci_component "$component" || return 1
        done
        return 0
      fi
      return 1
    }

    _cmd_pipeline_derive() {
      local id=$1 job=$2
      shift 2
      _valid_pipeline_run_id "$id" || { echo "otel-span: invalid PIPELINE_RUN_ID: $id" >&2; return 1; }
      [[ -n "$job" ]] || { echo "otel-span: missing pipeline job identifier" >&2; return 1; }
      local dim
      for dim in "$@"; do
        [[ "$dim" == *=* && -n "${dim%%=*}" && -n "${dim#*=}" ]] ||
          { echo "otel-span: invalid dimension: $dim" >&2; return 1; }
      done
      local trace root
      trace="$(_derive_pipeline_id buck2.job.trace/v1 32 "$id" "$job" "$@")" || return 1
      root="$(_derive_pipeline_id buck2.job.root/v1 16 "$id" "$job" "$@")" || return 1
      printf 'trace=%s root=%s\n' "$trace" "$root"
    }


for ((probe=0; probe<${RUNS:-200}; probe++)); do
  output=$(_cmd_pipeline_derive 'ci/github/example%2Frepo/1/1' typecheck) || { printf 'FAILED iteration=%s\n' "$probe" >&2; exit 1; }
  [[ $output == 'trace=8cf4c9f3e2169542eb872e9da0603050 root=b851a1bb6c4e07ff' ]] || { printf 'CORRUPT iteration=%s output=%s\n' "$probe" "$output" >&2; exit 1; }
done
printf 'passed %s exact identities\n' "${RUNS:-200}"
