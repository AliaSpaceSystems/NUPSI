# Piano: Script di controllo stato git dei repository NUPSI

**Data:** 2026-03-27
**Obiettivo:** Creare uno script bash che controlli se i repository locali che iniziano con `NUPSI-` sono allineati con i rispettivi remote, producendo un report finale.

---

## Analisi preliminare

### Repository trovati in `/media/LAVORO_EXTRA/AngularDevlopment/ALIA-SPACE/NUPSI/`

| Cartella               | Remote                                              | Branch corrente              |
|------------------------|-----------------------------------------------------|------------------------------|
| NUPSI-API              | https://github.com/edgardoambrosi/NUPSI_API.git     | main                         |
| NUPSI-CDN-cache        | https://github.com/AliaSpaceSystems/...             | MIGRATO_K8S_OVH              |
| NUPSI-DOCKER-CONTAINERS| https://github.com/AliaSpaceSystems/...             | main                         |
| NUPSI-FE               | https://github.com/AliaSpaceSystems/NUPSI-FE.git   | nupsi-1.1.0-webp_onboard     |
| NUPSI-FE-menu          | https://...@github.com/AliaSpaceSystems/...         | main                         |
| NUPSI-GEOJSON-server   | https://github.com/AliaSpaceSystems/...             | nupsi-1.1.0                  |
| NUPSI-Persistence      | https://github.com/AliaSpaceSystems/...             | main                         |
| NUPSI-STAC-json        | https://github.com/AliaSpaceSystems/...             | main                         |
| NUPSI-STAC-server      | https://github.com/AliaSpaceSystems/...             | MIGRATO_k8S_OVH              |
| NUPSI-STAC-server-live | https://...@github.com/AliaSpaceSystems/...         | MIGRATO_K8S_OVH              |

Tutti i 10 repository hanno `.git` inizializzato.

---

## Passi del piano

### Passo 1 — Scrivere il file di piano (questo file)
- **File:** `git-check-plan.md`
- **Azione:** Documentare obiettivo, analisi e passi prima di toccare il codice.
- **Stato:** COMPLETATO

### Passo 2 — Creare lo script bash `git-status-check.sh`
- **File:** `git-status-check.sh`
- **Logica:**
  1. Determinare la directory base (quella in cui si trova lo script oppure passata come argomento).
  2. Iterare su tutte le sottocartelle che corrispondono al pattern `NUPSI-*`.
  3. Per ciascuna cartella:
     a. Verificare che esista `.git` (skip se assente).
     b. Leggere la branch corrente con `git branch --show-current`.
     c. Eseguire `git fetch --quiet` per aggiornare i riferimenti remoti.
     d. Verificare che esista un tracking branch (`git rev-parse @{u}`); se assente segnalare `NO REMOTE TRACKING`.
     e. Confrontare locale vs remoto con `git rev-list`:
        - `LOCAL == REMOTE` → **AGGIORNATO**
        - `LOCAL` è indietro rispetto a `REMOTE` → **DA AGGIORNARE (BEHIND N commit)**
        - `LOCAL` è avanti rispetto a `REMOTE` → **DA PUSHARE (AHEAD N commit)**
        - Entrambi divergono → **DIVERGED (AHEAD A / BEHIND B commit)**
  4. Raccogliere tutti i risultati in un array (incluso l'ultimo commit locale via `git log -1 --format="%h %ad" --date=short`).
  5. Stampare il **report finale** con una tabella riepilogativa (REPOSITORY, BRANCH, ULTIMO COMMIT, STATO) e una sezione separata per i repo che richiedono azione.
- **Stato:** COMPLETATO

### Passo 3 — Rendere eseguibile lo script e verificarlo
- **Azioni:**
  - `chmod +x git-status-check.sh`
  - `bash -n git-status-check.sh` (controllo sintattico)
- **Stato:** COMPLETATO

---

## Criteri di accettazione

- Lo script gira senza errori da qualsiasi directory (usa path assoluti interni).
- Gestisce correttamente repo senza tracking branch remoto.
- Gestisce correttamente errori di rete su `git fetch` (timeout, autenticazione).
- Il report finale è leggibile a terminale con colori ANSI opzionali.
- Nessuna modifica viene apportata ai repository (solo lettura + fetch).
