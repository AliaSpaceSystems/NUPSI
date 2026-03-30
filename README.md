# NUPSI — Utility Scripts

Script e documentazione di supporto per la gestione operativa del progetto NUPSI (multi-repo, multi-container).

---

## File

### `git-status-check.sh`

Scansiona tutte le sottocartelle `NUPSI-*` e verifica l'allineamento di ciascun repository locale con il proprio remote.

**Utilizzo**
```bash
./git-status-check.sh [directory_base]
```
Se `directory_base` è omessa, usa la cartella dello script.

**Output**
- Stato per ogni repo in tempo reale (con colori ANSI)
- Report finale a tabella: `REPOSITORY | BRANCH | ULTIMO COMMIT | STATO`
- Dettaglio delle azioni richieste (`git pull` / `git push`)
- Exit code `0` se tutto è allineato, `1` se ci sono repo da gestire

**Stati possibili**

| Stato | Significato |
|---|---|
| `AGGIORNATO` | Locale = Remote |
| `DA AGGIORNARE` | Remote ha commit non pullati |
| `DA PUSHARE` | Locale ha commit non pushati |
| `DIVERGED` | Entrambi hanno commit divergenti |
| `NO TRACKING` | Nessun remote tracking branch configurato |
| `FETCH ERROR` | `git fetch` fallito (rete, auth) |

**Requisiti:** `bash >= 4`, accesso ai remote GitHub.

---

### `scan_vulnerabilities.sh`

Esegue una vulnerability assessment sulle immagini Docker `aliaspace/nupsi-*` usando **Trivy** e **Grype** in parallelo, limitando l'analisi alle severity `CRITICAL` e `HIGH`.

**Utilizzo**
```bash
./scan_vulnerabilities.sh
```

**Output**
- Dettaglio vulnerabilità per ogni immagine (Trivy + Grype)
- Executive summary a tabella con conteggi per immagine e totali
- Report salvato su file `vulnerability_report_<timestamp>.txt`

**Immagini analizzate** (tag `v1.1.0`)
- `nupsi-stac`, `nupsi-fe`, `nupsi-api`, `nupsi-geojsonserver`
- `nupsi-persistence`, `nupsi-cdncache`, `nupsi-stac-live`

**Requisiti:** [`trivy`](https://github.com/aquasecurity/trivy), [`grype`](https://github.com/anchore/grype), immagini disponibili localmente o su registry.

---

### `git-check-plan.md`

Documento di pianificazione che descrive obiettivo, analisi preliminare e criteri di accettazione di `git-status-check.sh`. Serve come riferimento per comprendere le decisioni progettuali dello script.
