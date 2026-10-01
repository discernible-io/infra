#!/bin/bash

# Script: scan-containers-vulnerabilities-weekly.sh
# Description: Container + source vulnerability scanning (Trivy)
# Usage: ./scan-containers-vulnerabilities-weekly.sh [OPTIONS]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/infra-env-helper.sh" ]]; then
    # shellcheck source=infra-env-helper.sh
    source "$SCRIPT_DIR/infra-env-helper.sh"
fi

INFRA_REPO="${INFRA_REPO:-$SCRIPT_DIR}"
INFRA_APP_DIR="${INFRA_APP_DIR:-$(cd "${INFRA_REPO}/.." && pwd)/infra-app}"
INFRA_OUTPUT_DIR="${INFRA_OUTPUT_DIR:-$INFRA_APP_DIR}"
INFRA_TRIVY_RESULTS_DIR="${INFRA_TRIVY_RESULTS_DIR:-${INFRA_OUTPUT_DIR}/trivy-scan-results}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER:-$(id -un)}}"
GHCR_ORG="${GHCR_ORG:-discernible-io}"

# Defaults (override via env or flags) — reports live under ~/infra-app, not the git checkout
SCAN_RESULTS_DIR="${SCAN_RESULTS_DIR:-$INFRA_TRIVY_RESULTS_DIR}"
SCAN_SEVERITY="${SCAN_SEVERITY:-HIGH,CRITICAL}"
PULL_MISSING="${PULL_MISSING:-0}"
INCLUDE_GIT_HEAD_IMAGES="${INCLUDE_GIT_HEAD_IMAGES:-1}"
INCLUDE_MONITORING_ENV_IMAGES="${INCLUDE_MONITORING_ENV_IMAGES:-1}"
SKIP_FS="${SKIP_FS:-0}"
SKIP_SBOM="${SKIP_SBOM:-0}"
FAIL_ON_FINDINGS="${FAIL_ON_FINDINGS:-0}"
SCAN_MANIFEST="${SCAN_MANIFEST:-$SCAN_RESULTS_DIR/scan-image-manifest.txt}"

PULL_MISSING_FLAG=0
INCLUDE_GIT_HEAD_FLAG=""
SKIP_FS_FLAG=""
SKIP_SBOM_FLAG=""
FAIL_ON_FINDINGS_FLAG=0

show_help() {
    cat << EOF
Container and Source Vulnerability Scanner (Trivy)

DESCRIPTION:
    Scans container images and (optionally) application source trees for
    vulnerabilities. Image discovery merges several sources so you see both
    what is running locally and what Git/registry tags ought to be deployed.

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help and exit
    --pull-missing          podman pull images that are not in the local store
    --no-git-head-images    Do not add ghcr.io/*:\$sha from *-idc git checkouts
    --skip-fs               Skip "trivy fs" on application repositories
    --skip-sbom             Skip CycloneDX SBOM export and diff
    --fail-on-findings      Exit 1 if any HIGH/CRITICAL findings are reported
    --severity LEVELS       Comma-separated severities (default: HIGH,CRITICAL)

IMAGE SOURCES (union, de-duplicated):
    1. Images referenced by running/stopped Podman containers (podman ps -a)
    2. Lines in \$SCAN_MANIFEST (default: $SCAN_RESULTS_DIR/scan-image-manifest.txt)
    3. ghcr.io/\$GHCR_ORG/<repo>/<image>:\$(git rev-parse HEAD) for each *-idc repo
       under \$INFRA_HOME (signsanctum, signportal, mintclient, api-test-scaffold, syntheticlc, slcbackend-slc)
    4. GRAFANA_IMAGE, LOKI_IMAGE from \$INFRA_HOME/grafanaloki-app/.env when present
    5. localhost/monitoring-nginx:latest when that tag exists locally

SCAN MODES PER IMAGE:
    - Local: podman save -> trivy --input (preferred; matches deployed layers)
    - Missing + --pull-missing: podman pull, then local export scan
    - Missing without pull: trivy image REF (registry scan; needs network/auth)

SOURCE / SBOM:
    - trivy fs on INFRA_HOME/*-idc repos (package.json, lockfiles)
    - CycloneDX SBOM per image under \$SCAN_RESULTS_DIR/sbom/
    - sbom-diff-\$TIMESTAMP.txt when a previous SBOM exists for the same image

OUTPUT:
    - trivy-scan-report-YYYYMMDD_HHMMSS.txt
    - trivy-summary-YYYYMMDD_HHMMSS.json
    - trivy-fs-YYYYMMDD_HHMMSS.txt (unless --skip-fs)
    - sbom/*.cyclonedx.json, sbom-diff-*.txt

REQUIREMENTS:
    - trivy, podman
    - Optional: jq

CI / TIMER:
    - Host: scan-containers-vulnerabilities-weekly.{service,timer}
    - GitHub: .github/workflows/container-vulnerability-scan.yml

EXAMPLES:
    $0
    $0 --pull-missing --fail-on-findings
    SCAN_SEVERITY=CRITICAL $0 --skip-fs

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        --pull-missing) PULL_MISSING_FLAG=1 ;;
        --no-git-head-images) INCLUDE_GIT_HEAD_FLAG=1 ;;
        --skip-fs) SKIP_FS_FLAG=1 ;;
        --skip-sbom) SKIP_SBOM_FLAG=1 ;;
        --fail-on-findings) FAIL_ON_FINDINGS_FLAG=1 ;;
        --severity)
            shift
            [[ $# -gt 0 ]] || { echo "Error: --severity requires a value" >&2; exit 1; }
            SCAN_SEVERITY="$1"
            ;;
        *) echo "Error: Unknown option '$1'" >&2; exit 1 ;;
    esac
    shift
done

[[ -n "$INCLUDE_GIT_HEAD_FLAG" ]] && INCLUDE_GIT_HEAD_IMAGES=0
[[ -n "$SKIP_FS_FLAG" ]] && SKIP_FS=1
[[ -n "$SKIP_SBOM_FLAG" ]] && SKIP_SBOM=1
[[ "$PULL_MISSING_FLAG" -eq 1 ]] && PULL_MISSING=1
[[ "$FAIL_ON_FINDINGS_FLAG" -eq 1 ]] && FAIL_ON_FINDINGS=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if ! command -v podman >/dev/null 2>&1; then
    echo -e "${RED}podman is not installed.${NC}" >&2
    exit 1
fi
if ! command -v trivy >/dev/null 2>&1; then
    echo -e "${RED}trivy is not installed.${NC}" >&2
    exit 1
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$SCAN_RESULTS_DIR/trivy-scan-report-$TIMESTAMP.txt"
FS_REPORT_FILE="$SCAN_RESULTS_DIR/trivy-fs-$TIMESTAMP.txt"
SBOM_DIR="$SCAN_RESULTS_DIR/sbom"
SCAN_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trivy-podman-scan.XXXXXX")
FINDINGS_COUNT=0

cleanup_scan_tmp() { rm -rf "$SCAN_TMP_DIR"; }
trap cleanup_scan_tmp EXIT

mkdir -p "$SCAN_RESULTS_DIR" "$SBOM_DIR"

# ── Image discovery ───────────────────────────────────────────────

declare -A IMAGE_SET=()

add_image() {
    local ref="$1"
    [[ -n "$ref" ]] || return 0
    IMAGE_SET["$ref"]=1
}

images_from_podman() {
    podman ps -a --format '{{.Image}}' 2>/dev/null | sort -u
}

images_from_manifest() {
    [[ -f "$SCAN_MANIFEST" ]] || return 0
    grep -vE '^\s*($|#)' "$SCAN_MANIFEST" || true
}

# ghcr.io/discernible-io/<repo>/<suffix>:<git-sha>
images_from_git_head() {
    local repo_dir repo sha suffix ghcr_repo
    declare -A repo_suffixes=(
        [signsanctum-idc]="signsanctum-api signsanctum-nginx"
        [signportal-idc]="signportal-app signportal-nginx"
        [mintclient-idc]="mintclient-app mintclient-nginx"
        [api-test-scaffold]="api-test-scaffold-api api-test-scaffold-nginx"
        [syntheticlc]="servertest-api servertest-nginx"
        [slcbackend-slc]="syntheticlc-api syntheticlc-nginx"
    )
    declare -A repo_ghcr_names=(
        [syntheticlc]=syntheticslastcradle
        [slcbackend-slc]=syntheticslastcradle
    )
    for repo_dir in "${!repo_suffixes[@]}"; do
        local dir="$INFRA_HOME/$repo_dir"
        [[ -d "$dir/.git" ]] || continue
        ghcr_repo="${repo_ghcr_names[$repo_dir]:-$repo_dir}"
        sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || continue
        for suffix in ${repo_suffixes[$repo_dir]}; do
            printf 'ghcr.io/%s/%s/%s:%s\n' "$GHCR_ORG" "$ghcr_repo" "$suffix" "$sha"
        done
    done
}

images_from_monitoring_env() {
    local env_file="$INFRA_HOME/grafanaloki-app/.env"
    [[ -f "$env_file" ]] || return 0
    # shellcheck disable=SC1090
    source "$env_file"
    [[ -n "${GRAFANA_IMAGE:-}" ]] && printf '%s\n' "$GRAFANA_IMAGE"
    [[ -n "${LOKI_IMAGE:-}" ]] && printf '%s\n' "$LOKI_IMAGE"
    if podman image exists localhost/monitoring-nginx:latest 2>/dev/null; then
        printf '%s\n' "localhost/monitoring-nginx:latest"
    fi
}

collect_images() {
    local src line
    while IFS= read -r line; do add_image "$line"; done < <(images_from_podman)
    while IFS= read -r line; do add_image "$line"; done < <(images_from_manifest)
    if [[ "$INCLUDE_GIT_HEAD_IMAGES" -eq 1 ]]; then
        while IFS= read -r line; do add_image "$line"; done < <(images_from_git_head)
    fi
    if [[ "$INCLUDE_MONITORING_ENV_IMAGES" -eq 1 ]]; then
        while IFS= read -r line; do add_image "$line"; done < <(images_from_monitoring_env)
    fi
}

sanitize_sbom_name() {
    echo "$1" | tr '/:@' '____'
}

count_trivy_vulns_from_json() {
    local json_file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH" or .Severity=="CRITICAL")] | length' \
            "$json_file" 2>/dev/null || echo 0
    else
        grep -c '"Severity": "HIGH"\|"Severity": "CRITICAL"' "$json_file" 2>/dev/null || echo 0
    fi
}

scan_local_tarball() {
    local image="$1"
    local image_id tar_file json_file
    image_id=$(podman image inspect "$image" --format '{{.Id}}')
    tar_file="${SCAN_TMP_DIR}/$(basename "${image_id#sha256:}").tar"
    json_file="${SCAN_TMP_DIR}/$(basename "${image_id#sha256:}").json"

    {
        echo "Local image ID: ${image_id}"
        echo "Scan method: podman save -> trivy --input"
        echo ""
    } >> "$REPORT_FILE"

    podman save -o "$tar_file" "$image"
    trivy image \
        --severity "$SCAN_SEVERITY" \
        --scanners vuln \
        --exit-code 0 \
        --format table \
        --input "$tar_file" 2>&1 | tee -a "$REPORT_FILE" >&2

    trivy image \
        --severity "$SCAN_SEVERITY" \
        --scanners vuln \
        --exit-code 0 \
        --format json \
        --quiet \
        --input "$tar_file" \
        -o "$json_file"
    count_trivy_vulns_from_json "$json_file"
}

scan_remote_image() {
    local image="$1"
    local json_file="${SCAN_TMP_DIR}/remote-$(sanitize_sbom_name "$image").json"
    {
        echo "Scan method: trivy image (registry; image not in local Podman store)"
        echo ""
    } >> "$REPORT_FILE"
    trivy image \
        --severity "$SCAN_SEVERITY" \
        --scanners vuln \
        --exit-code 0 \
        --format table \
        "$image" 2>&1 | tee -a "$REPORT_FILE" >&2
    trivy image \
        --severity "$SCAN_SEVERITY" \
        --scanners vuln \
        --exit-code 0 \
        --format json \
        --quiet \
        "$image" \
        -o "$json_file"
    count_trivy_vulns_from_json "$json_file"
}

export_sbom() {
    local image="$1"
    local safe sbom_file prev_file diff_file
    safe=$(sanitize_sbom_name "$image")
    sbom_file="$SBOM_DIR/${safe}.cyclonedx.json"
    prev_file="$SBOM_DIR/${safe}.cyclonedx.json.prev"

    trivy image --format cyclonedx --exit-code 0 --quiet "$image" -o "$sbom_file" 2>/dev/null || true

    [[ -s "$sbom_file" ]] || return 0

    if [[ -f "$prev_file" ]] && command -v jq >/dev/null 2>&1; then
        diff_file="$SCAN_RESULTS_DIR/sbom-diff-$TIMESTAMP.txt"
        {
            echo "=== SBOM component diff: $image ==="
            comm -3 \
                <(jq -r '.components[]? | (.purl // .name)' "$prev_file" 2>/dev/null | sort -u) \
                <(jq -r '.components[]? | (.purl // .name)' "$sbom_file" 2>/dev/null | sort -u) \
                | sed 's/^/  /' || true
            echo ""
        } >> "$diff_file"
    fi
    cp -f "$sbom_file" "$prev_file"
}

scan_one_image() {
    local image="$1"
    local vuln_count=0

    echo -e "${YELLOW}Scanning image: $image${NC}"
    {
        echo "=== Scanning: $image ==="
        echo "Scan started: $(date)"
        echo ""
    } >> "$REPORT_FILE"

    if podman image exists "$image" 2>/dev/null; then
        vuln_count=$(scan_local_tarball "$image") || return 1
    elif [[ "$PULL_MISSING" -eq 1 ]]; then
        echo -e "${YELLOW}Pulling missing image: $image${NC}"
        podman pull "$image"
        vuln_count=$(scan_local_tarball "$image") || return 1
    else
        echo -e "${YELLOW}Not in local store; scanning via registry: $image${NC}"
        vuln_count=$(scan_remote_image "$image") || return 1
    fi

    if [[ "$SKIP_SBOM" -eq 0 ]]; then
        export_sbom "$image" || true
    fi

    FINDINGS_COUNT=$((FINDINGS_COUNT + vuln_count))
    echo "" >> "$REPORT_FILE"
    echo "Vulnerability count (${SCAN_SEVERITY}): $vuln_count" >> "$REPORT_FILE"
    echo "----------------------------------------" >> "$REPORT_FILE"
    return 0
}

scan_filesystem_repos() {
  local -a repos=(
    "$INFRA_HOME/signsanctum-idc"
    "$INFRA_HOME/signportal-idc"
    "$INFRA_HOME/mintclient-idc"
    "$INFRA_HOME/api-test-scaffold"
    "$INFRA_HOME/syntheticlc"
    "$INFRA_HOME/slcbackend-slc"
  )
  local repo
  {
    echo "=== Trivy filesystem scan (source dependencies) ==="
    echo "Timestamp: $(date)"
    echo "Severity: $SCAN_SEVERITY"
    echo ""
  } > "$FS_REPORT_FILE"

  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || continue
    echo -e "${YELLOW}Filesystem scan: $repo${NC}"
    {
      echo "=== Repository: $repo ==="
      echo ""
    } >> "$FS_REPORT_FILE"
    trivy fs \
      --severity "$SCAN_SEVERITY" \
      --scanners vuln \
      --exit-code 0 \
      --format table \
      "$repo" 2>&1 | tee -a "$FS_REPORT_FILE" || true
    echo "" >> "$FS_REPORT_FILE"
  done
}

# ── Main ──────────────────────────────────────────────────────────

collect_images

echo -e "${BLUE}=== Trivy Container Security Scan Report ===${NC}"
echo -e "${BLUE}Timestamp: $(date)${NC}"
echo -e "${BLUE}Results: $REPORT_FILE${NC}"
echo -e "${BLUE}Image sources: podman ps -a, manifest, git HEAD, monitoring .env${NC}"
echo ""

{
    echo "=== Trivy Container Security Scan Report ==="
    echo "Timestamp: $(date)"
    echo "Severity filter: $SCAN_SEVERITY"
    echo "Pull missing images: $PULL_MISSING"
    echo "Include git HEAD GHCR refs: $INCLUDE_GIT_HEAD_IMAGES"
    echo "=========================================="
    echo ""
} > "$REPORT_FILE"

if [[ ${#IMAGE_SET[@]} -eq 0 ]]; then
    echo -e "${RED}No images to scan.${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Images to scan (${#IMAGE_SET[@]}):${NC}"
printf '  %s\n' "${!IMAGE_SET[@]}" | sort
echo ""

TOTAL_IMAGES=0
SCANNED_IMAGES=0
FAILED_SCANS=0

for IMAGE in $(printf '%s\n' "${!IMAGE_SET[@]}" | sort); do
    TOTAL_IMAGES=$((TOTAL_IMAGES + 1))
    if scan_one_image "$IMAGE"; then
        echo -e "${GREEN}✓ Scan completed for $IMAGE${NC}"
        SCANNED_IMAGES=$((SCANNED_IMAGES + 1))
    else
        echo -e "${RED}✗ Scan failed for $IMAGE${NC}"
        FAILED_SCANS=$((FAILED_SCANS + 1))
        echo "ERROR: Failed to scan $IMAGE" >> "$REPORT_FILE"
    fi
    sleep 1
done

if [[ "$SKIP_FS" -eq 0 ]]; then
    echo ""
    scan_filesystem_repos
    echo -e "Filesystem report: ${BLUE}$FS_REPORT_FILE${NC}"
fi

echo -e "${BLUE}=== Scan Summary ===${NC}"
echo -e "Total images: $TOTAL_IMAGES"
echo -e "Successfully scanned: ${GREEN}$SCANNED_IMAGES${NC}"
echo -e "Failed scans: ${RED}$FAILED_SCANS${NC}"
echo -e "Report: ${BLUE}$REPORT_FILE${NC}"

{
    echo ""
    echo "=== SCAN SUMMARY ==="
    echo "Total images: $TOTAL_IMAGES"
    echo "Successfully scanned: $SCANNED_IMAGES"
    echo "Failed scans: $FAILED_SCANS"
    echo "Filtered vulnerability findings (approx): $FINDINGS_COUNT"
    echo "Scan completed: $(date)"
} >> "$REPORT_FILE"

JSON_REPORT="$SCAN_RESULTS_DIR/trivy-summary-$TIMESTAMP.json"
if command -v jq &>/dev/null; then
    image_json=$(printf '%s\n' "${!IMAGE_SET[@]}" | sort | jq -R . | jq -s .)
    jq -n \
        --arg ts "$(date -Iseconds)" \
        --argjson images "$image_json" \
        --arg report "$REPORT_FILE" \
        --arg fs_report "$FS_REPORT_FILE" \
        --argjson total "$TOTAL_IMAGES" \
        --argjson scanned "$SCANNED_IMAGES" \
        --argjson failed "$FAILED_SCANS" \
        --argjson findings "$FINDINGS_COUNT" \
        --arg severity "$SCAN_SEVERITY" \
        '{
            scan_timestamp: $ts,
            severity: $severity,
            total_images: $total,
            scanned_images: $scanned,
            failed_scans: $failed,
            vulnerability_findings: $findings,
            images_scanned: $images,
            report_file: $report,
            filesystem_report_file: (if ($fs_report | length) > 0 then $fs_report else null end)
        }' > "$JSON_REPORT"
    echo -e "JSON summary: ${BLUE}$JSON_REPORT${NC}"
fi

echo -e "\n${YELLOW}Quick vulnerability summary (image totals):${NC}"
grep -E '^Total:|^Vulnerability count' "$REPORT_FILE" | head -20 || true

if [[ "$FAIL_ON_FINDINGS" -eq 1 && "$FINDINGS_COUNT" -gt 0 ]]; then
    echo -e "${RED}Failing: $FINDINGS_COUNT ${SCAN_SEVERITY} findings reported.${NC}" >&2
    exit 1
fi

if [[ "$FAILED_SCANS" -gt 0 ]]; then
    exit 1
fi

echo -e "${GREEN}Scan complete.${NC}"
