#!/bin/bash

# =============================================================================
# NUPSI - Vulnerability Assessment Report (Trivy + Grype)
# Images: aliaspace/nupsi-*:<tag>
#
# Uso: ./scan_vulnerabilities.sh [-p progetto] [-t tag] [tag]
#   -p, --project NOME  controlla solo l'immagine indicata (es. nupsi-api)
#   -t, --tag TAG       tag delle immagini (in alternativa come argomento posizionale)
# I valori non passati vengono chiesti interattivamente: progetto da menu
# (tutti o uno), tag con invio = DEFAULT_VERSION.
# =============================================================================

DEFAULT_VERSION="1.1.0"
IMAGE_PREFIX="aliaspace"
PROJECTS=(
    "nupsi-stac"
    "nupsi-fe"
    "nupsi-api"
    "nupsi-geojsonserver"
    "nupsi-persistence"
    "nupsi-cdncache"
    "nupsi-stac-live"
)
ALL_PROJECTS="Tutti i progetti"
# Formato tag Docker: [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}
TAG_REGEX='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'

usage() {
    echo "Uso: $(basename "$0") [-p progetto] [-t tag] [tag]"
    echo "Progetti: ${PROJECTS[*]}"
}

fail() {
    echo "Errore: $1" >&2
    exit 2
}

# ---------- argomenti ----------
VERSION=""
PROJECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project) [ -n "${2:-}" ] || fail "l'opzione $1 richiede un valore."; PROJECT="$2"; shift 2 ;;
        -t|--tag)     [ -n "${2:-}" ] || fail "l'opzione $1 richiede un valore."; VERSION="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           usage >&2; fail "opzione sconosciuta '$1'." ;;
        *)            [ -z "$VERSION" ] || fail "tag specificato due volte."; VERSION="$1"; shift ;;
    esac
done

# ---------- progetto: da -p, da menu (tutti o uno), tutti se non interattivo ----------
SELECTED=()
if [ -n "$PROJECT" ]; then
    for name in "${PROJECTS[@]}"; do
        [ "$name" == "$PROJECT" ] && SELECTED=("$name")
    done
    [ ${#SELECTED[@]} -gt 0 ] || fail "progetto '$PROJECT' non trovato. Disponibili: ${PROJECTS[*]}"
elif [ -t 0 ]; then
    echo "Progetti da controllare:"
    options=("$ALL_PROJECTS" "${PROJECTS[@]}")
    for i in "${!options[@]}"; do
        printf "  %2d) %s\n" $(( i + 1 )) "${options[$i]}"
    done
    while true; do
        read -r -p "Scegli il progetto [numero, invio = 1]: " choice || fail "nessun progetto scelto."
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            break
        fi
        echo "Scelta non valida."
    done
    if [ "$choice" -eq 1 ]; then
        SELECTED=("${PROJECTS[@]}")
    else
        SELECTED=("${options[$(( choice - 1 ))]}")
    fi
else
    SELECTED=("${PROJECTS[@]}")
fi

# ---------- tag ----------
if [ -z "$VERSION" ]; then
    if [ -t 0 ]; then
        read -r -p "Tag delle immagini da controllare [${DEFAULT_VERSION}]: " VERSION || VERSION=""
    fi
    VERSION="${VERSION:-$DEFAULT_VERSION}"
fi
[[ "$VERSION" =~ $TAG_REGEX ]] || fail "tag '$VERSION' non valido."

# ---------- tool e database vulnerabilità ----------
# I DB vengono aggiornati una sola volta qui: un DB scaduto non deve mai
# produrre un report "pulito". Le scansioni poi non riscaricano nulla.
for tool in trivy grype; do
    command -v "$tool" >/dev/null 2>&1 || fail "'$tool' non trovato nel PATH."
done
echo "Aggiornamento DB Trivy..."
trivy image --download-db-only --no-progress >/dev/null || fail "aggiornamento DB Trivy fallito."
# /tmp è tmpfs: la migrazione SQLite del DB Grype (>3 GB) lo satura
# ("database or disk is full") e ogni tentativo fallito lascia una
# directory grype-db-download* da ~1.5 GB nella cache.
GRYPE_DB_DIR="${GRYPE_DB_CACHE_DIR:-$HOME/.cache/grype/db}"
export GRYPE_TMPDIR="${GRYPE_TMPDIR:-$HOME/.cache/grype-tmp}"
mkdir -p "$GRYPE_TMPDIR" || fail "impossibile creare '$GRYPE_TMPDIR'."
rm -rf "$GRYPE_DB_DIR"/grype-db-download*
echo "Aggiornamento DB Grype..."
TMPDIR="$GRYPE_TMPDIR" grype db update >/dev/null || fail "aggiornamento DB Grype fallito."
export GRYPE_DB_AUTO_UPDATE=false

SCAN_ERR_FILE=$(mktemp) || fail "impossibile creare un file temporaneo."
trap 'rm -f "$SCAN_ERR_FILE"' EXIT

REPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_FILE="vulnerability_report_$(date '+%Y%m%d_%H%M%S').txt"

IMAGES=()
for name in "${SELECTED[@]}"; do
    IMAGES+=("${IMAGE_PREFIX}/${name}:${VERSION}")
done

# Per-image counters
declare -A TRIVY_CRITICAL
declare -A TRIVY_HIGH
declare -A GRYPE_CRITICAL
declare -A GRYPE_HIGH

TOTAL_TRIVY_CRITICAL=0
TOTAL_TRIVY_HIGH=0
TOTAL_GRYPE_CRITICAL=0
TOTAL_GRYPE_HIGH=0
SCAN_ERRORS=0

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

# Segnala una scansione fallita: i contatori diventano ERR invece di 0,
# così un errore non passa per "nessuna vulnerabilità".
report_scan_error() {
    local tool="$1" rc="$2"
    printf "  [ERR] %s scan failed (exit code %s):\n" "$tool" "$rc"
    grep -E "ERROR|FATAL|error" "$SCAN_ERR_FILE" | tail -5 | sed 's/^/    /'
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
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

    local trivy_raw trivy_rc trivy_output
    trivy_raw=$(trivy image \
        --severity CRITICAL,HIGH \
        --format table \
        --no-progress \
        --skip-db-update \
        "$image" 2>"$SCAN_ERR_FILE")
    trivy_rc=$?

    if [ "$trivy_rc" -ne 0 ]; then
        report_scan_error "Trivy" "$trivy_rc"
        TRIVY_CRITICAL["$short_name"]="ERR"
        TRIVY_HIGH["$short_name"]="ERR"
    else
        trivy_output=$(echo "$trivy_raw" | awk '
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

        # Trivy unisce le celle SEVERITY uguali: si contano le righe
        # "Total: N (HIGH: x, CRITICAL: y)" di ogni target, non le righe tabella
        local t_critical t_high
        t_critical=$(echo "$trivy_output" | grep -oE "CRITICAL: [0-9]+" | awk '{ s += $2 } END { print s + 0 }')
        t_high=$(echo "$trivy_output"     | grep -oE "HIGH: [0-9]+"     | awk '{ s += $2 } END { print s + 0 }')
        t_critical=${t_critical//[^0-9]/}; t_critical=${t_critical:-0}
        t_high=${t_high//[^0-9]/};         t_high=${t_high:-0}

        TRIVY_CRITICAL["$short_name"]=$t_critical
        TRIVY_HIGH["$short_name"]=$t_high
        TOTAL_TRIVY_CRITICAL=$((TOTAL_TRIVY_CRITICAL + t_critical))
        TOTAL_TRIVY_HIGH=$((TOTAL_TRIVY_HIGH + t_high))
    fi

    # --- GRYPE ---
    echo
    printf "  [GRYPE]\n"
    thin_separator

    local grype_raw grype_rc grype_output
    grype_raw=$(TMPDIR="$GRYPE_TMPDIR" grype "$image" -o table 2>"$SCAN_ERR_FILE")
    grype_rc=$?

    if [ "$grype_rc" -ne 0 ]; then
        report_scan_error "Grype" "$grype_rc"
        GRYPE_CRITICAL["$short_name"]="ERR"
        GRYPE_HIGH["$short_name"]="ERR"
        return
    fi

    # Match sulla colonna SEVERITY, non su "high" ovunque nella riga
    grype_output=$(echo "$grype_raw" | grep -E "[[:space:]](Critical|High)[[:space:]]" || true)

    if [ -n "$grype_output" ]; then
        echo "$grype_output"
    else
        printf "  No CRITICAL/HIGH vulnerabilities found by Grype.\n"
    fi

    local g_critical g_high
    g_critical=$(echo "$grype_output" | grep -cE "[[:space:]]Critical[[:space:]]"; true)
    g_high=$(echo "$grype_output"     | grep -cE "[[:space:]]High[[:space:]]";     true)
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

    if [ "$SCAN_ERRORS" -gt 0 ]; then
        printf "  [ERR] %s scan(s) failed — results are INCOMPLETE, see ERR above.\n" "$SCAN_ERRORS"
    fi
    if [ "$total_critical" -gt 0 ]; then
        printf "  [!] CRITICAL vulnerabilities found — IMMEDIATE remediation required.\n"
    elif [ "$SCAN_ERRORS" -eq 0 ]; then
        printf "  [OK] No CRITICAL vulnerabilities found.\n"
    fi
    if [ "$total_high" -gt 0 ]; then
        printf "  [!] HIGH vulnerabilities found — prompt attention required.\n"
    elif [ "$SCAN_ERRORS" -eq 0 ]; then
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

    [ "$SCAN_ERRORS" -eq 0 ]
} | tee "$REPORT_FILE"
SCAN_RC=${PIPESTATUS[0]}

echo "Report saved to: $REPORT_FILE"
exit "$SCAN_RC"
