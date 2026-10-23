# Tabula

Client database per macOS sul modello di TablePlus, per PostgreSQL e Amazon Aurora DSQL.
Con DSQL la password è un token IAM generato con la AWS CLI e le credenziali locali del
profilo scelto (SSO, assume-role, chiavi): Tabula lo rinnova da sola e ricrea la connessione
prima del limite di 60 minuti di DSQL o quando il server la chiude.

## Requisiti

- macOS 15+, Swift 6
- `brew install libpq` (per compilare; l'app finale include libpq nel bundle)
- AWS CLI v2 per le connessioni DSQL (`/opt/homebrew/bin/aws` o `/usr/local/bin/aws`)

## Comandi

```bash
swift test                       # test del nucleo
swift run Tabula                 # avvio in sviluppo
./scripts/build-app.sh           # build/Tabula.app firmata
./scripts/build-app.sh --install # copia in /Applications e apre
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

## Più connessioni

Ogni connessione si apre in una tab nativa della finestra (come "Open in new Tab" di TablePlus);
⌘K apre il selettore anche dentro il workspace, con "In una nuova finestra" per staccarla.
Per PostgreSQL ⌘D cambia database sullo stesso server. Il riquadro al centro della barra è
colorato secondo il tag; cliccandolo si vedono host, utente, token e i pulsanti Riconnetti/Disconnetti.

## Scorciatoie

⌘K apri connessione · ⌘D apri database · ⇧⌘0 gestisci connessioni · ⌘T nuova query ·
⌘↩ esegui statement corrente o selezione · ⇧⌘↩ esegui tutto · ⌘S salva modifiche · ⌘F filtri ·
⌘P cerca tabella · ⌘R aggiorna · ⇧⌘R riconnetti · ⇧⌘C console · ⌘] dettaglio riga
