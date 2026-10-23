# Tabula

Client database per macOS sul modello di TablePlus, per PostgreSQL e Amazon Aurora DSQL.
Con DSQL la password è un token IAM generato con la AWS CLI e le credenziali locali del
profilo scelto (SSO, assume-role, chiavi): Tabula lo rinnova da sola e ricrea la connessione
prima del limite di 60 minuti di DSQL o quando il server la chiude.

## Installazione

```bash
brew install --cask andreabasile/tap/tabula
```

Solo Apple Silicon, macOS 15+. L'app è firmata ma non notarizzata: il cask le toglie la quarantena
dopo l'installazione, altrimenti Gatekeeper ne bloccherebbe l'apertura.

## Sviluppo


- macOS 15+, Swift 6
- `brew install libpq` (per compilare; l'app finale include libpq nel bundle)
- AWS CLI v2 per le connessioni DSQL (`/opt/homebrew/bin/aws` o `/usr/local/bin/aws`)

## Comandi

```bash
swift test                       # test del nucleo
swift run Tabula                 # avvio in sviluppo
./scripts/build-app.sh           # build/Tabula.app firmata
./scripts/build-app.sh --install # copia in /Applications e apre
./scripts/release.sh 1.0.1       # release su GitHub e aggiornamento del cask nel tap
```

Avvio diretto su connessioni salvate: `Tabula --connect "<nome>" [--connect "<altra>"] [--table <tabella>]`.
Con `TABULA_SNAPSHOT_DIR=<cartella>` l'app salva ogni 3 secondi un PNG delle sue finestre
(serve a verificare l'interfaccia senza permessi di registrazione schermo).

## Come funziona il token DSQL

- `CachedTokenProvider` riusa il token finché manca più di un minuto alla scadenza;
  il token serve solo ad aprire la connessione, che poi resta valida.
- `ManagedSession` ricrea la connessione dopo 55 minuti (come i connettori AWS),
  e quando cade: le letture vengono ripetute, le scritture no.
- Se DSQL rifiuta un token in cache, ne genera uno nuovo e riprova una volta.
- La barra di stato mostra la validità del token, da quanto è aperta la connessione
  e quante riconnessioni ci sono state; "Riconnetti" (⇧⌘R) forza token e connessione nuovi.

## Script prima della connessione (tunnel)

Ogni connessione può avere uno script, salvato con lei, che Tabula lancia in una shell di
login zsh prima di collegarsi, ad esempio `bash ~/scripts/db-tunnel-prod.sh` per un tunnel SSM.

- "Apre un tunnel" (predefinito): lo script può restare attivo; Tabula lo lancia solo se
  host:porta non risponde già, attende che risponda (30 s di default), lo rilancia quando il
  tunnel cade e la connessione va ricreata, e chiude l'intero albero dei processi con l'ultima
  finestra che lo usa o all'uscita dall'app. Connessioni sulla stessa porta condividono il tunnel.
- Altrimenti lo script deve terminare con successo a ogni connessione (es. `aws sso login`).

Se fallisce, l'errore mostra le ultime righe del suo output. L'import da TablePlus porta con sé
il loro `StartupBashScript`.

## Import da TablePlus

"Importa da TablePlus…" nella finestra di benvenuto legge il file di File › Export Connections
(cifrato RNCryptor v3 con la password scelta all'export), mostra l'anteprima e importa gruppi,
tag, SSL, modalità sicura e password (nel Portachiavi). Le connessioni già presenti, stesso
host/porta/utente/database, restano deselezionate. Da terminale:
`TABULA_IMPORT_FILE=<file> TABULA_IMPORT_PASSWORD=<pw> Tabula`.

## Più connessioni

Come in TablePlus le connessioni aperte stanno nella colonna a sinistra della finestra, con
l'icona colorata secondo il tag; ⌘K ne apre un'altra, ⌘1…⌘9 passano dall'una all'altra.
Per PostgreSQL ⌘D cambia database sullo stesso server. Il riquadro al centro della barra è
colorato secondo il tag; cliccandolo si vedono host, utente, token e i pulsanti Riconnetti/Disconnetti.

## Scorciatoie

⌘K apri connessione · ⌘1…⌘9 cambia connessione · ⌘D apri database · ⇧⌘0 gestisci connessioni · ⌘T nuova query ·
⌘↩ esegui statement corrente o selezione · ⇧⌘↩ esegui tutto · ⌘S salva modifiche · ⌘F filtri ·
⌘P cerca tabella · ⌘R aggiorna · ⇧⌘R riconnetti · ⇧⌘C console · ⌘] dettaglio riga
