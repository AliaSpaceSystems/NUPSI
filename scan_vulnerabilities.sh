#!/bin/bash

# =============================================================================
# NUPSI - Vulnerability Assessment Report (Trivy + Grype)
# Images: aliaspace/nupsi-* v1.1.0
# =============================================================================

VERSION="1.1.0"
REPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_FILE="vulnerability_report_$(date '+%Y%m%d_%H%M%S').txt"

IMAGES=(
    "aliaspace/nupsi-stac:${VERSION}"
    "aliaspace/nupsi-fe:${VERSION}"
    "aliaspace/nupsi-api:${VERSION}"
    "aliaspace/nupsi-geojsonserver:${VERSION}"
    "aliaspace/nupsi-persistence:${VERSION}"
    "aliaspace/nupsi-cdncache:${VERSION}"
    "aliaspace/nupsi-stac-live:${VERSION}"
)

# Per-image counters
declare -A TRIVY_CRITICAL
declare -A TRIVY_HIGH
declare -A GRYPE_CRITICAL
declare -A GRYPE_HIGH

TOTAL_TRIVY_CRITICAL=0
TOTAL_TRIVY_HIGH=0
TOTAL_GRYPE_CRITICAL=0
TOTAL_GRYPE_HIGH=0

separator() {
    printf '%0.s=' {1..80}
    echo
}

thin_separator() {
    printf '%0.s-' {1..80}
    echo
}

print_header() {
    echo
    separator
    printf "  NUPSI VULNERABILITY ASSESSMENT REPORT\n"
    printf "  Date    : %s\n" "$REPORT_DATE"
    printf "  Version : %s\n" "$VERSION"
    printf "  Scope   : CRITICAL and HIGH severities only\n"
    printf "  Tools   : Trivy + Grype\n"
    separator
    echo
}

scan_image() {
    local image="$1"
    local short_name="${image%%:*}"
    short_name="${short_name##*/}"

    echo
    separator
    printf "  IMAGE: %s\n" "$image"
    separator

    # --- TRIVY ---
    echo
    printf "  [TRIVY]\n"
    thin_separator

    trivy image --clear-cache 2>/dev/null

    local trivy_output
    trivy_output=$(trivy image \
        --severity CRITICAL,HIGH \
        --format table \
        --no-progress \
        "$image" 2>/dev/null | awk '
            /^Report Summary/ { skip=1; next }
            skip && /^└/      { skip=0; next }
            skip              { next }
                              { print }
        ')

    if [ -n "$trivy_output" ]; then
        echo "$trivy_output"
    else
        printf "  No CRITICAL/HIGH vulnerabilities found by Trivy.\n"
    fi

    local t_critical t_high
    t_critical=$(echo "$trivy_output" | grep -c "| CRITICAL" 2>/dev/null; true)
    t_high=$(echo "$trivy_output"     | grep -c "| HIGH"     2>/dev/null; true)
    t_critical=${t_critical//[^0-9]/}; t_critical=${t_critical:-0}
    t_high=${t_high//[^0-9]/};         t_high=${t_high:-0}

    TRIVY_CRITICAL["$short_name"]=$t_critical
    TRIVY_HIGH["$short_name"]=$t_high
    TOTAL_TRIVY_CRITICAL=$((TOTAL_TRIVY_CRITICAL + t_critical))
    TOTAL_TRIVY_HIGH=$((TOTAL_TRIVY_HIGH + t_high))

    # --- GRYPE ---
    echo
    printf "  [GRYPE]\n"
    thin_separator

    local grype_output
    grype_output=$(grype "$image" -o table 2>/dev/null | grep -E "Critical|High" || true)

    if [ -n "$grype_output" ]; then
        echo "$grype_output"
    else
        printf "  No CRITICAL/HIGH vulnerabilities found by Grype.\n"
    fi

    local g_critical g_high
    g_critical=$(echo "$grype_output" | grep -ic "critical" 2>/dev/null; true)
    g_high=$(echo "$grype_output"     | grep -ic "high"     2>/dev/null; true)
    g_critical=${g_critical//[^0-9]/}; g_critical=${g_critical:-0}
    g_high=${g_high//[^0-9]/};         g_high=${g_high:-0}

    GRYPE_CRITICAL["$short_name"]=$g_critical
    GRYPE_HIGH["$short_name"]=$g_high
    TOTAL_GRYPE_CRITICAL=$((TOTAL_GRYPE_CRITICAL + g_critical))
    TOTAL_GRYPE_HIGH=$((TOTAL_GRYPE_HIGH + g_high))
}

print_summary() {
    echo
    separator
    printf "  EXECUTIVE SUMMARY — CRITICAL & HIGH VULNERABILITIES\n"
    separator
    printf "  %-30s  %10s  %8s  %10s  %8s\n" "IMAGE" "TRIVY-C" "TRIVY-H" "GRYPE-C" "GRYPE-H"
    printf "  %-30s  %10s  %8s  %10s  %8s\n" "-----" "-------" "-------" "-------" "-------"

    for image in "${IMAGES[@]}"; do
        local short="${image%%:*}"
        short="${short##*/}"
        printf "  %-30s  %10s  %8s  %10s  %8s\n" \
            "$short" \
            "${TRIVY_CRITICAL[$short]:-0}" \
            "${TRIVY_HIGH[$short]:-0}" \
            "${GRYPE_CRITICAL[$short]:-0}" \
            "${GRYPE_HIGH[$short]:-0}"
    done

    printf "  %-30s  %10s  %8s  %10s  %8s\n" "-----" "-------" "-------" "-------" "-------"
    printf "  %-30s  %10s  %8s  %10s  %8s\n" \
        "TOTAL" \
        "$TOTAL_TRIVY_CRITICAL" "$TOTAL_TRIVY_HIGH" \
        "$TOTAL_GRYPE_CRITICAL" "$TOTAL_GRYPE_HIGH"
    separator

    echo
    local total_critical=$(( TOTAL_TRIVY_CRITICAL > TOTAL_GRYPE_CRITICAL ? TOTAL_TRIVY_CRITICAL : TOTAL_GRYPE_CRITICAL ))
    local total_high=$(( TOTAL_TRIVY_HIGH > TOTAL_GRYPE_HIGH ? TOTAL_TRIVY_HIGH : TOTAL_GRYPE_HIGH ))

    if [ "$total_critical" -gt 0 ]; then
        printf "  [!] CRITICAL vulnerabilities found — IMMEDIATE remediation required.\n"
    else
        printf "  [OK] No CRITICAL vulnerabilities found.\n"
    fi
    if [ "$total_high" -gt 0 ]; then
        printf "  [!] HIGH vulnerabilities found — prompt attention required.\n"
    else
        printf "  [OK] No HIGH vulnerabilities found.\n"
    fi
    echo
    separator
    echo
}

# =============================================================================
# MAIN
# =============================================================================

{
    print_header

    for image in "${IMAGES[@]}"; do
        scan_image "$image"
    done

    print_summary

} | tee "$REPORT_FILE"

echo "Report saved to: $REPORT_FILE"
