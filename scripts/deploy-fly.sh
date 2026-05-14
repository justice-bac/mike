#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${ROOT_DIR}/backend"
FRONTEND_DIR="${ROOT_DIR}/frontend"
BACKEND_ENV_FILE="${BACKEND_DIR}/.env"
FRONTEND_ENV_FILE="${FRONTEND_DIR}/.env.local"
BACKEND_FLY_CONFIG="${BACKEND_DIR}/fly.toml"
FRONTEND_FLY_CONFIG="${FRONTEND_DIR}/fly.toml"

YES_MODE=0
DRY_RUN=0
WRITE_ENV_FILES="ask"
APP_PREFIX="${FLY_APP_PREFIX:-}"
FLY_ORG="${FLY_ORG:-}"
PRIMARY_REGION=""
BUILD_STRATEGY="${FLY_BUILD_STRATEGY:-auto}"

declare -A BACKEND_ENV_VALUES=()
declare -A FRONTEND_ENV_VALUES=()
declare -A BACKEND_SECRETS=()
declare -A FRONTEND_SECRETS=()
declare -A BACKEND_SECRET_SOURCES=()
declare -A FRONTEND_SECRET_SOURCES=()

RESOLVED_VALUE=""
RESOLVED_SOURCE=""
TEMP_FILES=()

usage() {
    cat <<'EOF'
Usage: ./scripts/deploy-fly.sh [options]

Interactive Fly.io deployment for Mike.

Options:
  --prefix VALUE           App prefix. Produces VALUE-mike-api and VALUE-mike-web.
                           Leave empty to use mike-api and mike-web.
  --org VALUE              Fly organization slug.
  --region VALUE           Fly primary region. Defaults to backend/fly.toml.
    --build-strategy VALUE   Build mode: auto, depot, remote, or local.
                                                     Defaults to auto.
  --dry-run                Print the deployment plan without creating apps,
                           uploading secrets, or deploying.
  --yes                    Do not prompt. Missing required values must already
                           exist in the shell environment or local env files.
  --write-env-files        Write non-derived deployment values back into local
                           env files.
  --no-write-env-files     Do not update local env files.
  -h, --help               Show this help.
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

warn() {
    printf 'Warning: %s\n' "$1" >&2
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
            --prefix)
                [[ $# -ge 2 ]] || die "--prefix requires a value"
                APP_PREFIX="$2"
                shift 2
                ;;
            --org)
                [[ $# -ge 2 ]] || die "--org requires a value"
                FLY_ORG="$2"
                shift 2
                ;;
            --region)
                [[ $# -ge 2 ]] || die "--region requires a value"
                PRIMARY_REGION="$2"
                shift 2
                ;;
            --build-strategy)
                [[ $# -ge 2 ]] || die "--build-strategy requires a value"
                BUILD_STRATEGY="$2"
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

validate_build_strategy() {
    case "${BUILD_STRATEGY}" in
        auto|depot|remote|local)
            ;;
        *)
            die "Invalid --build-strategy value: ${BUILD_STRATEGY}"
            ;;
    esac
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

prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local response=""

    if (( YES_MODE )); then
        printf '%s' "${default_value}"
        return 0
    fi

    if [[ -n "${default_value}" ]]; then
        read -r -p "${prompt_text} [${default_value}]: " response
        printf '%s' "${response:-${default_value}}"
        return 0
    fi

    read -r -p "${prompt_text}: " response
    printf '%s' "${response}"
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

set_secret() {
    local map_name="$1"
    local source_map_name="$2"
    local key="$3"
    local value="$4"
    local source="$5"
    local -n map_ref="$map_name"
    local -n source_ref="$source_map_name"

    map_ref["${key}"]="${value}"
    source_ref["${key}"]="${source}"
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

read_toml_string() {
    local file_path="$1"
    local key="$2"
    local fallback="$3"
    local value

    value="$(sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"/\1/p" "${file_path}" | head -n 1)"
    printf '%s' "${value:-${fallback}}"
}

compose_app_name() {
    local suffix="$1"
    if [[ -n "${APP_PREFIX}" ]]; then
        printf '%s-mike-%s' "${APP_PREFIX}" "${suffix}"
    else
        printf 'mike-%s' "${suffix}"
    fi
}

prepare_temp_fly_config() {
    local source_config="$1"
    local app_name="$2"
    local region="$3"
    local config_dir
    local config_name
    local temp_config

    config_dir="$(dirname "${source_config}")"
    config_name="$(basename "${source_config}")"
    temp_config="$(mktemp "${config_dir}/.${config_name%.toml}.XXXXXX.toml")"
    cp "${source_config}" "${temp_config}"
    sed -E -i "s/^app = .*/app = \"${app_name}\"/" "${temp_config}"
    if grep -q '^primary_region = ' "${temp_config}"; then
        sed -E -i "s/^primary_region = .*/primary_region = \"${region}\"/" "${temp_config}"
    else
        printf 'primary_region = "%s"\n' "${region}" >> "${temp_config}"
    fi
    TEMP_FILES+=("${temp_config}")
    printf '%s' "${temp_config}"
}

append_secret_arg() {
    local array_name="$1"
    local key="$2"
    local value="$3"
    local -n array_ref="$array_name"

    array_ref+=("${key}=${value}")
}

ensure_app_exists() {
    local app_name="$1"
    local org_slug="$2"

    if flyctl status --app "${app_name}" >/dev/null 2>&1; then
        info "Fly app already exists: ${app_name}"
        return 0
    fi

    info "Creating Fly app: ${app_name}"
    if [[ -n "${org_slug}" ]]; then
        flyctl apps create "${app_name}" --org "${org_slug}" --yes
    else
        flyctl apps create "${app_name}" --yes
    fi
}

has_local_builder() {
    command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1
}

ensure_fly_auth() {
    if [[ -n "${FLY_API_TOKEN:-}" ]]; then
        export FLY_ACCESS_TOKEN="${FLY_ACCESS_TOKEN:-${FLY_API_TOKEN}}"
        return 0
    fi

    if [[ -n "${FLY_ACCESS_TOKEN:-}" ]]; then
        export FLY_API_TOKEN="${FLY_API_TOKEN:-${FLY_ACCESS_TOKEN}}"
        return 0
    fi

    if flyctl auth whoami >/dev/null 2>&1; then
        return 0
    fi

    die "Fly auth not found. Run 'flyctl auth login' locally or set FLY_API_TOKEN for CI."
}

check_fly_network() {
    local log_file
    local doctor_output

    log_file="$(mktemp)"
    TEMP_FILES+=("${log_file}")

    if flyctl doctor >"${log_file}" 2>&1; then
        return 0
    fi

    doctor_output="$(cat "${log_file}")"

    if grep -Eqi 'gateway\.6pn\.dev.*connection reset by peer|failed to WebSocket dial|wireguard ping gateway' "${log_file}"; then
        die "Fly gateway connectivity is failing from this devcontainer. The current network is resetting connections to Fly's gateway, so source deploys from inside this container will not work until that path is fixed. Try one of: 1) deploy from a different network, 2) deploy from the host instead of the devcontainer, or 3) ask your network/VPN admins to allow HTTPS access to *.gateway.6pn.dev:443. Latest flyctl doctor output:\n${doctor_output}"
    fi

    warn "flyctl doctor reported problems, but not a known gateway reset pattern."
    warn "Latest flyctl doctor output follows:"
    printf '%s\n' "${doctor_output}" >&2
}

build_strategy_flags() {
    local flags_name="$1"
    local -n flags_ref="$flags_name"

    flags_ref=()
    case "${BUILD_STRATEGY}" in
        auto)
            ;;
        depot)
            flags_ref+=(--depot=true)
            ;;
        remote)
            flags_ref+=(--remote-only)
            ;;
        local)
            has_local_builder || die "--build-strategy local requires docker or podman in the devcontainer"
            flags_ref+=(--local-only)
            ;;
    esac
}

is_transient_builder_error() {
    local log_file="$1"
        grep -Eqi 'connection reset by peer|error reporting health|failed to fetch an image or build from source: error building: unavailable|read tcp .*:443: read:|waiting for depot builder|depot builder|unable to upgrade to h2c|received 500' "${log_file}"
}

print_builder_region_guidance() {
        cat >&2 <<'EOF'
Fly build failed in the builder/depot layer after retries.

This is commonly an org-level Fly builder region issue rather than an app config problem.

Recommended next step:
    1. Open Fly dashboard.
    2. Go to Org > Settings > App Builders > Configure.
    3. Change the builder region to a different region, such as ORD or IAD, if YYZ is unhealthy.
    4. Retry this deploy.

Notes:
    - Resetting a builder usually keeps it in the same region, so it may not help.
    - This devcontainer has no local Docker daemon, so --build-strategy local is not available here.
    - If you already tried depot, the region change is the next concrete fix.
EOF
}

run_deploy() {
    local service_name="$1"
    local workdir="$2"
    local config_path="$3"
    local app_name="$4"
    local deploy_flags=()
    local extra_flags=()
    local log_file
    local attempt=1

    build_strategy_flags deploy_flags

    while :; do
        log_file="$(mktemp)"
        TEMP_FILES+=("${log_file}")

        info "Deploying ${service_name} (attempt ${attempt})"
        if (( ${#extra_flags[@]} > 0 )); then
            info "  Extra flags: ${extra_flags[*]}"
        fi

        if flyctl deploy "${workdir}" --config "${config_path}" --app "${app_name}" "${deploy_flags[@]}" "${extra_flags[@]}" 2>&1 | tee "${log_file}"; then
            return 0
        fi

        if [[ "${BUILD_STRATEGY}" == "local" ]]; then
            return 1
        fi

        if (( attempt == 1 )) && is_transient_builder_error "${log_file}"; then
            warn "Fly builder connection failed while deploying ${service_name}. Retrying with --recreate-builder."
            extra_flags=(--recreate-builder)
            attempt=$((attempt + 1))
            continue
        fi

        if (( attempt == 2 )) && is_transient_builder_error "${log_file}" && [[ "${BUILD_STRATEGY}" == "auto" || "${BUILD_STRATEGY}" == "remote" ]]; then
            warn "Fly remote builder stayed unhealthy while deploying ${service_name}. Retrying with Depot."
            deploy_flags=(--depot=true)
            extra_flags=()
            attempt=$((attempt + 1))
            continue
        fi

        if is_transient_builder_error "${log_file}"; then
            print_builder_region_guidance
        fi

        return 1
    done
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
        if [[ -n "${BACKEND_SECRETS[${backend_key}]:-}" ]]; then
            upsert_env_file "${BACKEND_ENV_FILE}" "${backend_key}" "${BACKEND_SECRETS[${backend_key}]}"
        fi
    done

    for frontend_key in "${frontend_persist_keys[@]}"; do
        if [[ -n "${FRONTEND_SECRETS[${frontend_key}]:-}" ]]; then
            upsert_env_file "${FRONTEND_ENV_FILE}" "${frontend_key}" "${FRONTEND_SECRETS[${frontend_key}]}"
        fi
    done
}

print_secret_summary() {
    local title="$1"
    local source_map_name="$2"
    local secrets_map_name="$3"
    shift 3
    local key
    local -n source_ref="$source_map_name"
    local -n secrets_ref="$secrets_map_name"

    info ""
    info "${title}"
    for key in "$@"; do
        if [[ -z "${secrets_ref[${key}]:-}" ]]; then
            info "  - ${key}: skipped"
        else
            info "  - ${key}: $(mask_value "${key}" "${secrets_ref[${key}]}") [${source_ref[${key}]}]"
        fi
    done
}

main() {
    local default_region backend_app frontend_app backend_url frontend_url
    local backend_config frontend_config
    local backend_secret_args=()
    local frontend_secret_args=()
    local should_write_envs
    local backend_summary_keys=(
        FRONTEND_URL
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
    local frontend_summary_keys=(
        NEXT_PUBLIC_SITE_URL
        NEXT_PUBLIC_API_BASE_URL
        NEXT_PUBLIC_SUPABASE_URL
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY
        SUPABASE_SECRET_KEY
        R2_ENDPOINT_URL
        R2_ACCESS_KEY_ID
        R2_SECRET_ACCESS_KEY
        R2_BUCKET_NAME
    )

    parse_args "$@"
    require_command flyctl
    require_command node
    validate_build_strategy

    load_env_file "${BACKEND_ENV_FILE}" BACKEND_ENV_VALUES
    load_env_file "${FRONTEND_ENV_FILE}" FRONTEND_ENV_VALUES

    default_region="$(read_toml_string "${BACKEND_FLY_CONFIG}" primary_region yyz)"

    if [[ -z "${APP_PREFIX}" && ! ${YES_MODE} -eq 1 ]]; then
        APP_PREFIX="$(prompt_with_default "Fly app prefix (blank gives mike-api / mike-web)" "")"
    fi

    if [[ -z "${PRIMARY_REGION}" ]]; then
        PRIMARY_REGION="$(prompt_with_default "Fly primary region" "${default_region}")"
    fi

    if [[ -z "${FLY_ORG}" && ! ${YES_MODE} -eq 1 ]]; then
        FLY_ORG="$(prompt_with_default "Fly organization slug (blank uses your default org)" "")"
    fi

    backend_app="$(compose_app_name api)"
    frontend_app="$(compose_app_name web)"
    backend_url="https://${backend_app}.fly.dev"
    frontend_url="https://${frontend_app}.fly.dev"

    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES FRONTEND_URL "${frontend_url}" "derived from frontend app name"
    resolve_generated 32 DOWNLOAD_SIGNING_SECRET
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES DOWNLOAD_SIGNING_SECRET "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase project URL" 0 SUPABASE_URL NEXT_PUBLIC_SUPABASE_URL
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES SUPABASE_URL "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase service role key" 1 SUPABASE_SECRET_KEY
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES SUPABASE_SECRET_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 endpoint URL" 0 R2_ENDPOINT_URL
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES R2_ENDPOINT_URL "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 access key ID" 0 R2_ACCESS_KEY_ID
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES R2_ACCESS_KEY_ID "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 secret access key" 1 R2_SECRET_ACCESS_KEY
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES R2_SECRET_ACCESS_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 bucket name" 0 R2_BUCKET_NAME
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES R2_BUCKET_NAME "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_generated 32 USER_API_KEYS_ENCRYPTION_SECRET API_KEYS_ENCRYPTION_SECRET
    set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES USER_API_KEYS_ENCRYPTION_SECRET "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_optional GEMINI_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES GEMINI_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    resolve_optional ANTHROPIC_API_KEY CLAUDE_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES ANTHROPIC_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    resolve_optional OPENAI_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES OPENAI_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    resolve_optional RESEND_API_KEY
    if [[ -n "${RESOLVED_VALUE}" ]]; then
        set_secret BACKEND_SECRETS BACKEND_SECRET_SOURCES RESEND_API_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"
    fi

    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES NEXT_PUBLIC_SITE_URL "${frontend_url}" "derived from frontend app name"
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES NEXT_PUBLIC_API_BASE_URL "${backend_url}" "derived from backend app name"

    resolve_required "Supabase public URL" 0 NEXT_PUBLIC_SUPABASE_URL SUPABASE_URL
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES NEXT_PUBLIC_SUPABASE_URL "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase anon key" 1 NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "Supabase service role key" 1 SUPABASE_SECRET_KEY
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES SUPABASE_SECRET_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 endpoint URL" 0 R2_ENDPOINT_URL
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES R2_ENDPOINT_URL "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 access key ID" 0 R2_ACCESS_KEY_ID
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES R2_ACCESS_KEY_ID "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 secret access key" 1 R2_SECRET_ACCESS_KEY
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES R2_SECRET_ACCESS_KEY "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    resolve_required "R2 bucket name" 0 R2_BUCKET_NAME
    set_secret FRONTEND_SECRETS FRONTEND_SECRET_SOURCES R2_BUCKET_NAME "${RESOLVED_VALUE}" "${RESOLVED_SOURCE}"

    info ""
    info "Fly deployment plan"
    info "  Backend app:  ${backend_app}"
    info "  Frontend app: ${frontend_app}"
    info "  Backend URL:  ${backend_url}"
    info "  Frontend URL: ${frontend_url}"
    info "  Region:       ${PRIMARY_REGION}"
    info "  Organization: ${FLY_ORG:-default}"
    info "  Build mode:   ${BUILD_STRATEGY}"

    print_secret_summary "Backend secrets" BACKEND_SECRET_SOURCES BACKEND_SECRETS "${backend_summary_keys[@]}"
    print_secret_summary "Frontend secrets" FRONTEND_SECRET_SOURCES FRONTEND_SECRETS "${frontend_summary_keys[@]}"

    if (( DRY_RUN )); then
        info ""
        info "Dry run only. No Fly apps, secrets, or deployments were changed."
        return 0
    fi

    ensure_fly_auth
    check_fly_network

    should_write_envs=0
    case "${WRITE_ENV_FILES}" in
        yes)
            should_write_envs=1
            ;;
        no)
            should_write_envs=0
            ;;
        ask)
            if confirm_yes "Write non-derived deployment values back into backend/.env and frontend/.env.local?" yes; then
                should_write_envs=1
            fi
            ;;
    esac

    if ! confirm_yes "Continue with Fly app creation, secret upload, and deployment?" yes; then
        info "Aborted."
        return 0
    fi

    ensure_app_exists "${backend_app}" "${FLY_ORG}"
    ensure_app_exists "${frontend_app}" "${FLY_ORG}"

    backend_config="$(prepare_temp_fly_config "${BACKEND_FLY_CONFIG}" "${backend_app}" "${PRIMARY_REGION}")"
    frontend_config="$(prepare_temp_fly_config "${FRONTEND_FLY_CONFIG}" "${frontend_app}" "${PRIMARY_REGION}")"

    local key
    for key in "${!BACKEND_SECRETS[@]}"; do
        append_secret_arg backend_secret_args "${key}" "${BACKEND_SECRETS[${key}]}"
    done
    for key in "${!FRONTEND_SECRETS[@]}"; do
        append_secret_arg frontend_secret_args "${key}" "${FRONTEND_SECRETS[${key}]}"
    done

    info ""
    info "Staging backend secrets"
    flyctl secrets set --stage --app "${backend_app}" "${backend_secret_args[@]}"

    info "Staging frontend secrets"
    flyctl secrets set --stage --app "${frontend_app}" "${frontend_secret_args[@]}"

    if (( should_write_envs )); then
        persist_local_env_files
        info "Updated local env files with non-derived deployment values."
    fi

    info ""
    run_deploy backend "${BACKEND_DIR}" "${backend_config}" "${backend_app}"

    info ""
    run_deploy frontend "${FRONTEND_DIR}" "${frontend_config}" "${frontend_app}"

    info ""
    info "Deployment complete"
    info "  Backend health:  ${backend_url}/health"
    info "  Frontend health: ${frontend_url}/api/health"
}

main "$@"