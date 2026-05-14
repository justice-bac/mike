#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_ENV_FILE="${ROOT_DIR}/backend/.env"
FRONTEND_ENV_FILE="${ROOT_DIR}/frontend/.env.local"

YES_MODE=0
DRY_RUN=0
WRITE_ENV_FILES="ask"
REPO="${GITHUB_REPOSITORY:-}"
GITHUB_AUTH_SOURCE="not checked"

declare -A BACKEND_ENV_VALUES=()
declare -A FRONTEND_ENV_VALUES=()
declare -A GITHUB_SECRETS=()
declare -A GITHUB_SECRET_SOURCES=()

RESOLVED_VALUE=""
RESOLVED_SOURCE=""
TEMP_FILES=()

usage() {
cat <<'EOF'
Usage: ./scripts/sync-github-secrets.sh [options]

Sync local deployment values into GitHub repository secrets for the Fly deploy workflow.

Options:
  --repo VALUE            Repository in owner/name form. Defaults to the current
                          repository context used by gh.
  --dry-run               Print the secret sync plan without writing GitHub secrets.
  --yes                   Do not prompt. Missing required values must already
                          exist in the shell environment, local env files, flyctl auth,
                          or GH_TOKEN/GITHUB_TOKEN.
  --write-env-files       Write generated/shared values back into local env files.
  --no-write-env-files    Do not update local env files.
  -h, --help              Show this help.
EOF
}

cleanup() {
    local file
    for file in "${TEMP_FILES[@]}"; do
        [[ -f "${file}" ]] && rm -f "${file}"
    done
}

trap cleanup EXIT

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

info() {
    printf '%s\n' "$1"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                [[ $# -ge 2 ]] || die "--repo requires a value"
                REPO="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                YES_MODE=1
                shift
                ;;
            --write-env-files)
                WRITE_ENV_FILES="yes"
                shift
                ;;
            --no-write-env-files)
                WRITE_ENV_FILES="no"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

load_env_file() {
    local file_path="$1"
    local map_name="$2"
    local -n map_ref="$map_name"

    map_ref=()
    [[ -f "${file_path}" ]] || return 0

    while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
        local line key value
        line="${raw_line%$'\r'}"
        [[ -z "$(trim "${line}")" ]] && continue
        [[ "$(trim "${line}")" == \#* ]] && continue

        if [[ "${line}" == export* ]]; then
            line="${line#export}"
        fi

        if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="$(trim "${BASH_REMATCH[2]}")"

            if [[ "${value}" == \#* ]]; then
                value=""
            elif [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
                value="${value:1:-1}"
                value="${value//\\n/$'\n'}"
                value="${value//\\\"/\"}"
                value="${value//\\\\/\\}"
            elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
                value="${value:1:-1}"
            else
                value="${value%%[[:space:]]#*}"
                value="$(trim "${value}")"
            fi

            map_ref["${key}"]="${value}"
        fi
    done < "${file_path}"
}

lookup_candidates() {
    local candidate
    for candidate in "$@"; do
        if [[ -n "${!candidate:-}" ]]; then
            RESOLVED_VALUE="${!candidate}"
            RESOLVED_SOURCE="shell environment (${candidate})"
            return 0
        fi
    done

    for candidate in "$@"; do
        if [[ -n "${BACKEND_ENV_VALUES[${candidate}]:-}" ]]; then
            RESOLVED_VALUE="${BACKEND_ENV_VALUES[${candidate}]}"
            RESOLVED_SOURCE="backend/.env (${candidate})"
            return 0
        fi
    done

    for candidate in "$@"; do
        if [[ -n "${FRONTEND_ENV_VALUES[${candidate}]:-}" ]]; then
            RESOLVED_VALUE="${FRONTEND_ENV_VALUES[${candidate}]}"
            RESOLVED_SOURCE="frontend/.env.local (${candidate})"
            return 0
        fi
    done

    return 1
}

prompt_required_value() {
    local prompt_text="$1"
    local hidden="$2"
    local response=""

    if (( YES_MODE )); then
        return 1
    fi

    while [[ -z "${response}" ]]; do
        if (( hidden )); then
            read -r -s -p "${prompt_text}: " response
            printf '\n'
        else
            read -r -p "${prompt_text}: " response
        fi
        response="$(trim "${response}")"
    done

    RESOLVED_VALUE="${response}"
    RESOLVED_SOURCE="interactive prompt"
    return 0
}

confirm_yes() {
    local prompt_text="$1"
    local default_yes="$2"
    local answer=""

    if (( YES_MODE )); then
        [[ "${default_yes}" == "yes" ]]
        return 0
    fi

    if [[ "${default_yes}" == "yes" ]]; then
        read -r -p "${prompt_text} [Y/n]: " answer
        answer="${answer:-Y}"
    else
        read -r -p "${prompt_text} [y/N]: " answer
        answer="${answer:-N}"
    fi

    [[ "${answer}" =~ ^[Yy]$ ]]
}

generate_hex_secret() {
    local byte_count="$1"
    node -e "console.log(require('crypto').randomBytes(${byte_count}).toString('hex'))"
}

resolve_required() {
    local prompt_text="$1"
    local hidden="$2"
    shift 2

    if lookup_candidates "$@"; then
        return 0
    fi

    prompt_required_value "${prompt_text}" "${hidden}" || die "Missing required value for ${1}"
}

resolve_optional() {
    if lookup_candidates "$@"; then
        return 0
    fi

    RESOLVED_VALUE=""
    RESOLVED_SOURCE="not provided"
    return 0
}

resolve_generated() {
    local byte_count="$1"
    shift

    if lookup_candidates "$@"; then
        return 0
    fi

    RESOLVED_VALUE="$(generate_hex_secret "${byte_count}")"
    RESOLVED_SOURCE="generated"
}

resolve_fly_api_token() {
    if lookup_candidates FLY_API_TOKEN FLY_ACCESS_TOKEN; then
        return 0
    fi

    if command -v flyctl >/dev/null 2>&1; then
        local token
        token="$(flyctl auth token 2>/dev/null || true)"
        if [[ -n "${token}" ]]; then
            RESOLVED_VALUE="${token}"
            RESOLVED_SOURCE="flyctl auth token"
            return 0
        fi
    fi

    prompt_required_value "Fly API token" 1 || die "Missing required value for FLY_API_TOKEN"
}

ensure_gh_auth() {
    if [[ -n "${GH_TOKEN:-}" ]]; then
        GITHUB_AUTH_SOURCE="shell environment (GH_TOKEN)"
        return 0
    fi

    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        export GH_TOKEN="${GITHUB_TOKEN}"
        GITHUB_AUTH_SOURCE="shell environment (GITHUB_TOKEN)"
        return 0
    fi

    if gh auth status >/dev/null 2>&1; then
        GITHUB_AUTH_SOURCE="gh stored login"
        return 0
    fi

    prompt_required_value "GitHub token with repo, read:org, and gist scopes" 1 || die "GitHub CLI is not authenticated and no GH_TOKEN/GITHUB_TOKEN was provided"
    export GH_TOKEN="${RESOLVED_VALUE}"
    GITHUB_AUTH_SOURCE="interactive prompt"
}

set_secret() {
    local key="$1"
    local value="$2"
    local source="$3"

    GITHUB_SECRETS["${key}"]="${value}"
    GITHUB_SECRET_SOURCES["${key}"]="${source}"
}

mask_value() {
    local key="$1"
    local value="$2"

    if [[ -z "${value}" ]]; then
        printf '(empty)'
        return 0
    fi

    case "${key}" in
        *URL|R2_BUCKET_NAME)
            printf '%s' "${value}"
            ;;
        *)
            if (( ${#value} <= 8 )); then
                printf '********'
            else
                printf '%s...%s' "${value:0:4}" "${value: -4}"
            fi
            ;;
    esac
}

quote_env_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    printf '"%s"' "${value}"
}

upsert_env_file() {
    local file_path="$1"
    local key="$2"
    local value="$3"
    local quoted_value
    local temp_file

    mkdir -p "$(dirname "${file_path}")"
    [[ -f "${file_path}" ]] || touch "${file_path}"

    quoted_value="$(quote_env_value "${value}")"
    temp_file="$(mktemp)"
    TEMP_FILES+=("${temp_file}")
    awk -v target_key="${key}" -v target_value="${quoted_value}" '
        BEGIN { updated = 0 }
        $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=" {
            print target_key "=" target_value
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print target_key "=" target_value
            }
        }
    ' "${file_path}" > "${temp_file}"
    mv "${temp_file}" "${file_path}"
}

persist_local_env_files() {
    local backend_key frontend_key
    local backend_persist_keys=(
        DOWNLOAD_SIGNING_SECRET
        SUPABASE_URL
        SUPABASE_SECRET_KEY
        R2_ENDPOINT_URL
        R2_ACCESS_KEY_ID
        R2_SECRET_ACCESS_KEY
        R2_BUCKET_NAME
        USER_API_KEYS_ENCRYPTION_SECRET
        GEMINI_API_KEY
        ANTHROPIC_API_KEY
        OPENAI_API_KEY
        RESEND_API_KEY
    )
    local frontend_persist_keys=(
        NEXT_PUBLIC_SUPABASE_URL
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY
        SUPABASE_SECRET_KEY
        R2_ENDPOINT_URL
        R2_ACCESS_KEY_ID
        R2_SECRET_ACCESS_KEY
        R2_BUCKET_NAME
    )

    for backend_key in "${backend_persist_keys[@]}"; do
        if [[ -n "${GITHUB_SECRETS[${backend_key}]:-}" ]]; then
            upsert_env_file "${BACKEND_ENV_FILE}" "${backend_key}" "${GITHUB_SECRETS[${backend_key}]}"
        fi
    done

    for frontend_key in "${frontend_persist_keys[@]}"; do
        if [[ -n "${GITHUB_SECRETS[${frontend_key}]:-}" ]]; then
            upsert_env_file "${FRONTEND_ENV_FILE}" "${frontend_key}" "${GITHUB_SECRETS[${frontend_key}]}"
        fi
    done
}

repo_args() {
    local array_name="$1"
    local -n array_ref="$array_name"

    array_ref=()
    if [[ -n "${REPO}" ]]; then
        array_ref+=(--repo "${REPO}")
    fi
}

print_summary() {
    local key
    local keys=(
        FLY_API_TOKEN
        SUPABASE_URL
        NEXT_PUBLIC_SUPABASE_URL
        SUPABASE_SECRET_KEY
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY
        R2_ENDPOINT_URL
        R2_ACCESS_KEY_ID
        R2_SECRET_ACCESS_KEY
        R2_BUCKET_NAME
        DOWNLOAD_SIGNING_SECRET
        USER_API_KEYS_ENCRYPTION_SECRET
        GEMINI_API_KEY
        ANTHROPIC_API_KEY
        OPENAI_API_KEY
        RESEND_API_KEY
    )

    info ""
    info "GitHub secret sync plan"
    info "  Repository: ${REPO:-current gh repo context}"
    info "  GitHub auth: ${GITHUB_AUTH_SOURCE}"
    for key in "${keys[@]}"; do
        if [[ -z "${GITHUB_SECRETS[${key}]:-}" ]]; then
            info "  - ${key}: skipped"
        else
            info "  - ${key}: $(mask_value "${key}" "${GITHUB_SECRETS[${key}]}") [${GITHUB_SECRET_SOURCES[${key}]}]"
        fi
    done
}

sync_secret() {
    local key="$1"
    local value="$2"
    local args=()

    repo_args args
    gh secret set "${key}" "${args[@]}" --body "${value}"
}

main() {
    local should_write_envs
    local key

    parse_args "$@"
    require_command gh
    require_command node

    load_env_file "${BACKEND_ENV_FILE}" BACKEND_ENV_VALUES
    load_env_file "${FRONTEND_ENV_FILE}" FRONTEND_ENV_VALUES

    resolve_fly_api_token
    set_secret FLY_API_TOKEN "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase project URL" 0 SUPABASE_URL NEXT_PUBLIC_SUPABASE_URL
    set_secret SUPABASE_URL "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase public URL" 0 NEXT_PUBLIC_SUPABASE_URL SUPABASE_URL
    set_secret NEXT_PUBLIC_SUPABASE_URL "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase service role key" 1 SUPABASE_SECRET_KEY
    set_secret SUPABASE_SECRET_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase anon key" 1 NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY
    set_secret NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 endpoint URL" 0 R2_ENDPOINT_URL
    set_secret R2_ENDPOINT_URL "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 access key ID" 0 R2_ACCESS_KEY_ID
    set_secret R2_ACCESS_KEY_ID "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 secret access key" 1 R2_SECRET_ACCESS_KEY
    set_secret R2_SECRET_ACCESS_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 bucket name" 0 R2_BUCKET_NAME
    set_secret R2_BUCKET_NAME "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_generated 32 DOWNLOAD_SIGNING_SECRET
    set_secret DOWNLOAD_SIGNING_SECRET "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_generated 32 USER_API_KEYS_ENCRYPTION_SECRET API_KEYS_ENCRYPTION_SECRET
    set_secret USER_API_KEYS_ENCRYPTION_SECRET "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_optional GEMINI_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret GEMINI_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    resolve_optional ANTHROPIC_API_KEY CLAUDE_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret ANTHROPIC_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    resolve_optional OPENAI_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret OPENAI_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    resolve_optional RESEND_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret RESEND_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    if (( ! DRY_RUN )); then
        ensure_gh_auth
    fi

    print_summary

    if (( DRY_RUN )); then
        info ""
        info "Dry run only. No GitHub secrets were changed."
        return 0
    fi

    should_write_envs=0
    case "${WRITE_ENV_FILES}" in
        yes)
            should_write_envs=1
            ;;
        no)
            should_write_envs=0
            ;;
        ask)
            if confirm_yes "Write generated/shared values back into backend/.env and frontend/.env.local?" yes; then
                should_write_envs=1
            fi
            ;;
    esac

    if ! confirm_yes "Continue syncing repository secrets to GitHub Actions?" yes; then
        info "Aborted."
        return 0
    fi

    for key in "${!GITHUB_SECRETS[@]}"; do
        info "Setting GitHub secret: ${key}"
        sync_secret "${key}" "${GITHUB_SECRETS[${key}]}"
    done

    if (( should_write_envs )); then
        persist_local_env_files
        info "Updated local env files with generated/shared values."
    fi

    info ""
    info "GitHub Actions secrets updated."
}

main "$@"
