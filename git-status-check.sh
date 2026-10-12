#!/usr/bin/env bash
# =============================================================================
# git-status-check.sh
# Controlla se i repository locali NUPSI-* sono allineati con il remote.
# Le cartelle contenitore (es. NUPSI-FE) vengono espanse nei loro figli.
# Al termine propone di aggiornare (solo git pull) i repo indietro rispetto al remote.
#
# Modalità --new-branch: crea un nuovo branch locale e remoto (origin) su uno
# dei progetti gestiti, partendo da origin/<branch_base>.
#
# Uso:
#   ./git-status-check.sh [directory_base]
#   ./git-status-check.sh --new-branch [-p progetto] [-b nuovo_branch] [-f branch_base] [-y] [directory_base]
# Se directory_base non è specificata, usa la cartella dove si trova lo script.
# I valori non passati in --new-branch vengono chiesti interattivamente.
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
# Argomenti
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Uso:
  $(basename "$0") [directory_base]
      Controlla lo stato dei repository NUPSI-* e propone git pull.

  $(basename "$0") --new-branch [opzioni] [directory_base]
      Crea un nuovo branch locale + remoto (origin) su un progetto.
      -p, --project NOME    progetto (es. NUPSI-CDN-cache o NUPSI-FE/NUPSI-FE-MAPLIBRE)
      -b, --branch NOME     nome del nuovo branch
      -f, --from NOME       branch di partenza su origin (default: branch corrente)
      -y, --yes             non chiedere conferma prima di creare e pushare
  -h, --help              mostra questo aiuto
EOF
}

require_arg() {
    if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
        echo -e "${RED}Errore: l'opzione $1 richiede un valore.${RESET}" >&2
        usage >&2
        exit 2
    fi
}

MODE="check"
NB_PROJECT=""
NB_BRANCH=""
NB_BASE=""
NB_YES=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--new-branch) MODE="new-branch"; shift ;;
        -p|--project)    require_arg "$1" "${2:-}"; NB_PROJECT="$2"; shift 2 ;;
        -b|--branch)     require_arg "$1" "${2:-}"; NB_BRANCH="$2"; shift 2 ;;
        -f|--from)       require_arg "$1" "${2:-}"; NB_BASE="$2"; shift 2 ;;
        -y|--yes)        NB_YES=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*)
            echo -e "${RED}Errore: opzione sconosciuta '$1'.${RESET}" >&2
            usage >&2
            exit 2
            ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

if [[ "$MODE" == "check" && ( -n "$NB_PROJECT" || -n "$NB_BRANCH" || -n "$NB_BASE" || "$NB_YES" == true ) ]]; then
    echo -e "${RED}Errore: -p/-b/-f/-y si usano solo con --new-branch.${RESET}" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Directory base
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${POSITIONAL[0]:-$SCRIPT_DIR}"
BASE_DIR="${BASE_DIR%/}"

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
# Discovery delle cartelle NUPSI-* (contenitori espansi nei figli)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Modalità --new-branch: crea un branch locale + remoto su un progetto
# ---------------------------------------------------------------------------

# Mostra un elenco numerato su stderr e stampa su stdout la voce scelta
choose_from_list() {
    local prompt="$1"; shift
    local items=("$@") i choice
    for i in "${!items[@]}"; do
        printf "  %2d) %s\n" $(( i + 1 )) "${items[$i]}" >&2
    done
    while true; do
        read -r -p "$prompt" choice || return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            echo "${items[$(( choice - 1 ))]}"
            return 0
        fi
        echo -e "${YELLOW}Scelta non valida.${RESET}" >&2
    done
}

nb_fail() {
    echo -e "${RED}Errore: $1${RESET}" >&2
    exit 1
}

nb_require_tty() {
    [[ -t 0 ]] || nb_fail "input non interattivo: specificare $1 (vedi --help)."
}

# Sceglie il progetto: da -p (nome relativo o basename) oppure da menu
nb_select_project() {
    local projects=() dir name
    for dir in "${NUPSI_DIRS[@]}"; do
        [[ -d "$dir/.git" ]] && projects+=("${dir#"$BASE_DIR"/}")
    done
    [[ ${#projects[@]} -gt 0 ]] || nb_fail "nessun repository git NUPSI-* trovato in $BASE_DIR."

    if [[ -z "$NB_PROJECT" ]]; then
        nb_require_tty "-p progetto"
        echo -e "${BOLD}Progetti disponibili:${RESET}"
        NB_PROJECT=$(choose_from_list "Scegli il progetto [numero]: " "${projects[@]}") \
            || nb_fail "nessun progetto scelto."
        return
    fi

    for name in "${projects[@]}"; do
        if [[ "$NB_PROJECT" == "$name" || "$NB_PROJECT" == "$(basename "$name")" ]]; then
            NB_PROJECT="$name"
            return
        fi
    done
    nb_fail "progetto '$NB_PROJECT' non trovato. Disponibili: ${projects[*]}"
}

# Sceglie il branch di partenza (default: branch corrente) e verifica che esista su origin
nb_select_base() {
    local repo="$1" current answer
    current=$(git -C "$repo" branch --show-current 2>/dev/null || echo "")

    if [[ -z "$NB_BASE" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Branch di partenza su origin [${current:-nessuno}]: " answer || answer=""
            NB_BASE="${answer:-$current}"
        else
            NB_BASE="$current"
        fi
    fi
    [[ -n "$NB_BASE" ]] || nb_fail "HEAD detached: specificare il branch di partenza con -f."

    if ! git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$NB_BASE" >/dev/null; then
        nb_fail "il branch di partenza 'origin/$NB_BASE' non esiste."
    fi
}

# Chiede/valida il nome del nuovo branch e verifica che non esista né in locale né su origin
nb_select_new_name() {
    local repo="$1"
    if [[ -z "$NB_BRANCH" ]]; then
        nb_require_tty "-b nuovo_branch"
        read -r -p "Nome del nuovo branch: " NB_BRANCH || NB_BRANCH=""
    fi
    [[ -n "$NB_BRANCH" ]] || nb_fail "nome del nuovo branch vuoto."

    git check-ref-format --branch "$NB_BRANCH" >/dev/null 2>&1 \
        || nb_fail "'$NB_BRANCH' non è un nome di branch valido."
    if git -C "$repo" rev-parse --verify --quiet "refs/heads/$NB_BRANCH" >/dev/null; then
        nb_fail "il branch '$NB_BRANCH' esiste già in locale."
    fi
    if git -C "$repo" ls-remote --exit-code --heads origin "$NB_BRANCH" >/dev/null 2>&1; then
        nb_fail "il branch '$NB_BRANCH' esiste già su origin."
    fi
}

nb_confirm() {
    local answer
    [[ "$NB_YES" == true ]] && return 0
    nb_require_tty "-y per confermare senza prompt"
    read -r -p "$1 [s/N]: " answer || answer=""
    [[ "${answer,,}" == "s" ]]
}

create_branch_flow() {
    local repo base_ref base_info ahead dirty

    echo ""
    echo -e "${BOLD}${CYAN}================================================================${RESET}"
    echo -e "${BOLD}${CYAN}  NUPSI - Creazione nuovo branch                                ${RESET}"
    echo -e "${BOLD}${CYAN}  Directory base: $BASE_DIR${RESET}"
    echo -e "${BOLD}${CYAN}================================================================${RESET}"
    echo ""

    nb_select_project
    repo="$BASE_DIR/$NB_PROJECT"

    git -C "$repo" remote get-url origin >/dev/null 2>&1 \
        || nb_fail "il progetto '$NB_PROJECT' non ha un remote 'origin'."

    echo -e "  ${CYAN}git fetch origin${RESET} → ${BOLD}${NB_PROJECT}${RESET}"
    git -C "$repo" fetch --prune --quiet origin || nb_fail "git fetch fallito su '$NB_PROJECT'."

    nb_select_base "$repo"
    nb_select_new_name "$repo"

    base_ref="origin/$NB_BASE"
    base_info=$(git -C "$repo" log -1 --format="%h %s" "$base_ref")

    echo ""
    echo -e "${BOLD}Riepilogo:${RESET}"
    echo -e "  Progetto:      ${BOLD}${NB_PROJECT}${RESET}"
    echo -e "  Nuovo branch:  ${BOLD}${NB_BRANCH}${RESET} (locale + origin/${NB_BRANCH})"
    echo -e "  Parte da:      ${BOLD}${base_ref}${RESET} → ${base_info:0:70}"

    # Commit locali del branch base non ancora su origin: non finiranno nel nuovo branch
    if git -C "$repo" rev-parse --verify --quiet "refs/heads/$NB_BASE" >/dev/null; then
        ahead=$(git -C "$repo" rev-list --count "$base_ref..refs/heads/$NB_BASE" 2>/dev/null || echo "0")
        if [[ "$ahead" -gt 0 ]]; then
            echo -e "  ${YELLOW}Attenzione: '$NB_BASE' locale ha ${ahead} commit non pushati che NON saranno inclusi.${RESET}"
        fi
    fi

    dirty=$(git -C "$repo" status --porcelain 2>/dev/null || echo "")
    if [[ -n "$dirty" ]]; then
        echo -e "  ${YELLOW}Attenzione: ci sono modifiche non committate; verranno portate sul nuovo branch.${RESET}"
    fi
    echo ""

    nb_confirm "Creare il branch e pusharlo su origin?" || { echo "Operazione annullata."; exit 0; }

    echo -e "  ${CYAN}git switch -c ${NB_BRANCH} ${base_ref}${RESET}"
    git -C "$repo" switch --quiet --no-track -c "$NB_BRANCH" "$base_ref" \
        || nb_fail "creazione del branch locale fallita (nessuna modifica su origin)."

    echo -e "  ${CYAN}git push -u origin ${NB_BRANCH}${RESET}"
    if ! git -C "$repo" push --quiet -u origin "$NB_BRANCH"; then
        echo -e "${RED}Push fallito: il branch '${NB_BRANCH}' esiste solo in locale.${RESET}" >&2
        echo -e "Per riprovare: git -C \"$repo\" push -u origin \"$NB_BRANCH\"" >&2
        exit 1
    fi

    echo ""
    echo -e "${GREEN}Branch '${NB_BRANCH}' creato su ${NB_PROJECT} (locale + origin) e attivo.${RESET}"
    echo ""
    exit 0
}

if [[ "$MODE" == "new-branch" ]]; then
    create_branch_flow
fi

# ---------------------------------------------------------------------------
# Main: controllo stato delle cartelle NUPSI-*
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo -e "${BOLD}${CYAN}  NUPSI Git Status Check                                        ${RESET}"
echo -e "${BOLD}${CYAN}  Directory base: $BASE_DIR${RESET}"
echo -e "${BOLD}${CYAN}================================================================${RESET}"
echo ""

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
