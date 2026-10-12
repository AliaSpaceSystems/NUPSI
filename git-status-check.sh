#!/usr/bin/env bash
# =============================================================================
# git-status-check.sh
# Controlla se i repository locali NUPSI-* sono allineati con il remote.
# Le cartelle contenitore (es. NUPSI-FE) vengono espanse nei loro figli.
# Al termine propone di aggiornare (solo git pull) i repo indietro rispetto al remote.
# Uso: ./git-status-check.sh [directory_base]
# Se directory_base non è specificata, usa la cartella dove si trova lo script.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colori ANSI
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Directory base
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${1:-$SCRIPT_DIR}"

if [[ ! -d "$BASE_DIR" ]]; then
    echo -e "${RED}Errore: la directory '$BASE_DIR' non esiste.${RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Strutture dati per il report
# ---------------------------------------------------------------------------
declare -a REPO_NAMES=()
declare -a REPO_BRANCHES=()
declare -a REPO_STATUSES=()
declare -a REPO_DETAILS=()
declare -a REPO_LAST_COMMITS=()

# Cartelle contenitore: non sono repository, ma contengono repository figli
CONTAINER_DIRS=("NUPSI-FE")

# ---------------------------------------------------------------------------
# Funzione: analizza un singolo repository
# ---------------------------------------------------------------------------
check_repo() {
    local repo_path="$1"
    local repo_name
    repo_name="${repo_path#"$BASE_DIR"/}"

    # Verifica presenza di .git
    if [[ ! -d "$repo_path/.git" ]]; then
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("-")
        REPO_STATUSES+=("NO GIT")
        REPO_DETAILS+=("Nessun repository git trovato")
        REPO_LAST_COMMITS+=("-")
        return
    fi

    # Branch corrente
    local branch
    branch=$(git -C "$repo_path" branch --show-current 2>/dev/null || echo "")
    if [[ -z "$branch" ]]; then
        # HEAD detached
        branch="(detached HEAD)"
    fi

    # Ultimo commit locale (messaggio, troncato a 45 caratteri)
    local last_commit
    last_commit=$(git -C "$repo_path" log -1 --format="%s" 2>/dev/null || echo "-")
    last_commit="${last_commit:0:45}"

    # git fetch (aggiorna i riferimenti remoti senza modificare i file locali)
    local fetch_error=""
    if ! git -C "$repo_path" fetch --quiet 2>/tmp/nupsi_fetch_err; then
        fetch_error=$(cat /tmp/nupsi_fetch_err)
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("FETCH ERROR")
        REPO_DETAILS+=("git fetch fallito: ${fetch_error:0:120}")
        REPO_LAST_COMMITS+=("$last_commit")
        return
    fi

    # Verifica tracking branch
    local upstream
    upstream=$(git -C "$repo_path" rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || echo "")
    if [[ -z "$upstream" ]]; then
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("NO TRACKING")
        REPO_DETAILS+=("Nessun remote tracking branch configurato per '$branch'")
        REPO_LAST_COMMITS+=("$last_commit")
        return
    fi

    # Commit di differenza locale vs remoto
    local local_sha remote_sha
    local_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")
    remote_sha=$(git -C "$repo_path" rev-parse "@{upstream}" 2>/dev/null || echo "")

    if [[ -z "$local_sha" || -z "$remote_sha" ]]; then
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("ERRORE")
        REPO_DETAILS+=("Impossibile leggere SHA locale o remoto")
        REPO_LAST_COMMITS+=("$last_commit")
        return
    fi

    if [[ "$local_sha" == "$remote_sha" ]]; then
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("AGGIORNATO")
        REPO_DETAILS+=("In linea con $upstream")
        REPO_LAST_COMMITS+=("$last_commit")
        return
    fi

    local ahead behind
    ahead=$(git -C "$repo_path" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "0")
    behind=$(git -C "$repo_path" rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo "0")

    if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("DIVERGED")
        REPO_DETAILS+=("${ahead} commit locali non pushati, ${behind} commit remoti non pullati")
        REPO_LAST_COMMITS+=("$last_commit")
    elif [[ "$behind" -gt 0 ]]; then
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("DA AGGIORNARE")
        REPO_DETAILS+=("Indietro di ${behind} commit rispetto a $upstream — eseguire: git pull")
        REPO_LAST_COMMITS+=("$last_commit")
    elif [[ "$ahead" -gt 0 ]]; then
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("DA PUSHARE")
        REPO_DETAILS+=("Avanti di ${ahead} commit rispetto a $upstream — eseguire: git push")
        REPO_LAST_COMMITS+=("$last_commit")
    else
        # Fallback (non dovrebbe accadere)
        REPO_NAMES+=("$repo_name")
        REPO_BRANCHES+=("$branch")
        REPO_STATUSES+=("SCONOSCIUTO")
        REPO_DETAILS+=("SHA diversi ma conteggio ahead/behind = 0")
        REPO_LAST_COMMITS+=("$last_commit")
    fi
}

# ---------------------------------------------------------------------------
# Main: scansione delle cartelle NUPSI-*
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}${CYAN}  NUPSI Git Status Check                                        ${RESET}"
echo -e "${BOLD}${CYAN}  Directory base: $BASE_DIR${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo ""

is_container() {
    local name="$1" c
    for c in "${CONTAINER_DIRS[@]}"; do
        [[ "$name" == "$c" ]] && return 0
    done
    return 1
}

NUPSI_DIRS=()
while IFS= read -r dir; do
    if is_container "$(basename "$dir")"; then
        # Espande la cartella contenitore nei suoi figli diretti
        while IFS= read -r child; do
            NUPSI_DIRS+=("$child")
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d | sort)
    else
        NUPSI_DIRS+=("$dir")
    fi
done < <(find "$BASE_DIR" -maxdepth 1 -type d -name "NUPSI-*" | sort)

if [[ ${#NUPSI_DIRS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Nessuna cartella NUPSI-* trovata in $BASE_DIR${RESET}"
    exit 0
fi

echo -e "Trovati ${BOLD}${#NUPSI_DIRS[@]}${RESET} repository. Avvio controllo...\n"

for dir in "${NUPSI_DIRS[@]}"; do
    repo_name="${dir#"$BASE_DIR"/}"
    echo -ne "  Controllo ${CYAN}${repo_name}${RESET}..."
    check_repo "$dir"
    status="${REPO_STATUSES[-1]}"
    case "$status" in
        "AGGIORNATO")    echo -e " ${GREEN}${status}${RESET}" ;;
        "DA AGGIORNARE") echo -e " ${RED}${status}${RESET}" ;;
        "DA PUSHARE")    echo -e " ${YELLOW}${status}${RESET}" ;;
        "DIVERGED")      echo -e " ${RED}${status}${RESET}" ;;
        *)               echo -e " ${YELLOW}${status}${RESET}" ;;
    esac
done

# ---------------------------------------------------------------------------
# Report finale
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}${CYAN}  REPORT FINALE                                                 ${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}"
printf "\n${BOLD}%-35s %-32s %-47s %-18s${RESET}\n" "REPOSITORY" "BRANCH" "ULTIMO COMMIT" "STATO"
printf "%-35s %-32s %-47s %-18s\n" "-----------------------------------" "--------------------------------" "-----------------------------------------------" "------------------"

count_ok=0
count_warn=0

for i in "${!REPO_NAMES[@]}"; do
    name="${REPO_NAMES[$i]}"
    branch="${REPO_BRANCHES[$i]}"
    status="${REPO_STATUSES[$i]}"
    detail="${REPO_DETAILS[$i]}"
    last_commit="${REPO_LAST_COMMITS[$i]}"

    case "$status" in
        "AGGIORNATO")
            printf "${GREEN}%-35s %-32s %-47s %-18s${RESET}\n" "$name" "$branch" "$last_commit" "$status"
            count_ok=$(( count_ok + 1 ))
            ;;
        "DA AGGIORNARE"|"DIVERGED")
            printf "${RED}%-35s %-32s %-47s %-18s${RESET}\n" "$name" "$branch" "$last_commit" "$status"
            count_warn=$(( count_warn + 1 ))
            ;;
        "DA PUSHARE")
            printf "${YELLOW}%-35s %-32s %-47s %-18s${RESET}\n" "$name" "$branch" "$last_commit" "$status"
            count_warn=$(( count_warn + 1 ))
            ;;
        *)
            printf "${YELLOW}%-35s %-32s %-47s %-18s${RESET}\n" "$name" "$branch" "$last_commit" "$status"
            count_warn=$(( count_warn + 1 ))
            ;;
    esac
done

echo ""
echo -e "${BOLD}Riepilogo:${RESET}  ${GREEN}${count_ok} aggiornati${RESET}  |  ${RED}${count_warn} richiedono attenzione${RESET}"

# Dettagli per i repo che richiedono azione
needs_action=()
for i in "${!REPO_NAMES[@]}"; do
    if [[ "${REPO_STATUSES[$i]}" != "AGGIORNATO" ]]; then
        needs_action+=("$i")
    fi
done

if [[ ${#needs_action[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}Dettagli repository da gestire:${RESET}"
    for i in "${needs_action[@]}"; do
        echo -e "  ${BOLD}${REPO_NAMES[$i]}${RESET} [${REPO_BRANCHES[$i]}]"
        echo -e "    → ${REPO_DETAILS[$i]}"
    done
fi

# ---------------------------------------------------------------------------
# Aggiornamento interattivo: solo git pull sui repo DA AGGIORNARE
# ---------------------------------------------------------------------------
to_pull=()
for i in "${!REPO_NAMES[@]}"; do
    [[ "${REPO_STATUSES[$i]}" == "DA AGGIORNARE" ]] && to_pull+=("$i")
done

if [[ ${#to_pull[@]} -gt 0 ]]; then
    echo ""
    if [[ ! -t 0 ]]; then
        echo -e "${YELLOW}Input non interattivo: pull non eseguito.${RESET}"
    else
        echo -e "${BOLD}Repository da aggiornare (git pull):${RESET}"
        for i in "${to_pull[@]}"; do
            echo -e "  - ${REPO_NAMES[$i]} [${REPO_BRANCHES[$i]}]"
        done
        answer=""
        read -r -p "Eseguire git pull? [t]utti / [s]celta singola / [N]o: " answer || answer=""
        case "${answer,,}" in
            t|tutti) mode="all" ;;
            s|scelta) mode="ask" ;;
            *) mode="none" ;;
        esac

        if [[ "$mode" != "none" ]]; then
            for i in "${to_pull[@]}"; do
                name="${REPO_NAMES[$i]}"
                if [[ "$mode" == "ask" ]]; then
                    reply=""
                    read -r -p "  git pull su ${name}? [s/N]: " reply || reply=""
                    [[ "${reply,,}" == "s" ]] || { echo "    saltato"; continue; }
                fi
                echo -e "  ${CYAN}git pull${RESET} → ${BOLD}${name}${RESET}"
                if git -C "$BASE_DIR/$name" pull --ff-only; then
                    REPO_STATUSES[$i]="AGGIORNATO"
                    count_warn=$(( count_warn - 1 ))
                    echo -e "    ${GREEN}OK${RESET}"
                else
                    echo -e "    ${RED}git pull fallito${RESET}"
                fi
            done
        else
            echo "Nessun pull eseguito."
        fi
    fi
fi

echo ""
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo ""

# Exit code: 0 se tutto aggiornato, 1 se ci sono repo da gestire
if [[ $count_warn -gt 0 ]]; then
    exit 1
else
    exit 0
fi
