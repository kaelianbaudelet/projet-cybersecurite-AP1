# DBBackup CLI

## Presentation

DBBackup CLI est un utilitaire Bash destine a la sauvegarde et a la restauration de bases MariaDB/MySQL. Le script cree des dumps, les compresse, les chiffre en AES-256-CBC, genere des sommes SHA-256, et peut transferer les sauvegardes vers des serveurs distants avant de nettoyer les fichiers temporaires. Il integre en plus la gestion de planifications cron et une verification d integrite.

Fonctionnalites principales :

- Sauvegardes locales et distantes en une commande.
- Chiffrement AES-256-CBC avec cle stockee dans `config/encryption.key`.
- Sommes de controle SHA-256 pour verifier l integrite.
- Transferts SFTP/SSH et nettoyage des sauvegardes distantes obsoletes.
- Planification via cron avec activation/desactivation dynamique.
- Restauration guidee avec verification optionnelle de la sauvegarde.

## Prerequis

- Client MariaDB/MySQL (`mysql` et `mysqldump`).
- `openssl` et `gzip` pour le chiffrement et la compression.
- `ssh` et `scp`, plus `sshpass` si vous utilisez un mot de passe SSH.
- Acces a `crontab` pour les planifications.

## Lancer l outil

- Placez vous dans `dbbackup-cli` et lancez `./dbbackup --help` pour voir le rappel d utilisation.
- Les commandes utilisent la configuration stockee dans `config/dbbackup.conf`; ajustez ce fichier si necessaire.

## Commandes principales

### `dbbackup backup`

Cree une sauvegarde de base de donnees, compressee, chiffree et optionnellement transferee vers un serveur distant.

Options utiles :

- `-h|--host` hote MariaDB (defaut `localhost`).
- `-P|--port` port MariaDB (defaut `3306`).
- `-u|--user` utilisateur MariaDB (obligatoire).
- `-p|--password` mot de passe (obligatoire).
- `-d|--database` base a sauvegarder (obligatoire).
- `-o|--output` dossier local (defaut `backups/`).
- `--encrypt` / `--no-encrypt` active ou desactive le chiffrement (defaut actif).
- `--transfer` / `--no-transfer` force ou interdit l envoi distant.
- `--remote <nom>` choisit un serveur distant et active automatiquement le transfert (utilise `config/remotes/<nom>.conf`).

Exemples :

```bash
# Sauvegarde locale simple
./dbbackup backup -u root -p secret -d mydb

# Sauvegarde sans chiffrement
./dbbackup backup -u admin -p pass -d production --no-encrypt

# Sauvegarde et envoi vers le remote "prod"
./dbbackup backup -u root -p secret -d mydb --remote prod
```

#### `dbbackup backup list`

Liste les sauvegardes locales ou distantes disponibles.

Options :

- `-o|--output <dossier>` analyse un dossier specifique.
- `--remote` (optionnellement `--remote=<nom>`) affiche les sauvegardes sur un serveur distant. Sans nom, le serveur par defaut est utilise.

Exemples :

```bash
# Lister les fichiers locaux
./dbbackup backup list

# Lister les sauvegardes distantes depuis "prod"
./dbbackup backup list --remote=prod
```

### `dbbackup restore`

Restaure une base a partir d une sauvegarde locale ou distante. Le script decompresse, dechiffre et valide la somme de controle avant d utiliser `mysql`.

Options :

- `-f|--file <chemin>` fichier de sauvegarde (obligatoire sauf `--list`).
- `-h|--host`, `-P|--port`, `-u|--user`, `-p|--password`, `-d|--database` parametrent la base cible.
- `--remote` telecharge la sauvegarde depuis le serveur distant actif (utilise le nom passe a `-f` relatif au repertoire distant).
- `--verify` verifie l integrite sans restaurer.
- `--list` affiche les sauvegardes locales disponibles.

Le script verifie l existence de la base, peut la creer sur demande, et requiert la confirmation `yes` avant d ecraser une base existante.

Exemples :

```bash
# Restaurer une sauvegarde locale chiffree
./dbbackup restore -f backups/mydb_20241110_020000.sql.gz.enc -u root -p secret -d mydb

# Verifier uniquement la sauvegarde
./dbbackup restore -f backups/mydb_20241110_020000.sql.gz.enc --verify

# Restaurer un fichier present sur le serveur distant "prod"
./dbbackup restore -f daily/mydb-2024-11-10.sql.gz.enc --remote -u root -p secret -d mydb
```

### `dbbackup schedule`

Gere les sauvegardes planifiees via cron. Toutes les planifications sont stockees dans `config/schedules.conf`.

Sous-commandes :

- `schedule add` : ajoute une planification. Necessite `-n|--name`, `-c|--cron`, `-u|--user`, `-p|--password`, `-d|--database`. `--remote <nom>` rend la planification distante.
- `schedule list` : affiche un tableau des planifications configurees et leur statut.
- `schedule modify <nom>` : met a jour cron, hote, identifiants ou serveur distant (`--remote` ou `--no-remote`).
- `schedule remove <nom>` : supprime la planification et la tache cron associee.
- `schedule enable <nom>` / `schedule disable <nom>` : active ou desactive la planification tout en installant/retirant la tache cron.
- `schedule next` : rappelle la prochaine execution theorique pour chaque planification active.

Exemples :

```bash
# Planifier une sauvegarde quotidienne locale a 02h00
./dbbackup schedule add -n daily -c "0 2 * * *" -u root -p secret -d mydb

# Ajouter une sauvegarde distante
./dbbackup schedule add -n daily-remote -c "0 3 * * *" -u root -p secret -d mydb --remote prod

# Modifier une planification pour retirer le transfert distant
./dbbackup schedule modify daily-remote --no-remote

# Suspendre puis reactiver une planification
./dbbackup schedule disable daily
./dbbackup schedule enable daily
```

### `dbbackup remote`

Administre les serveurs distants utilises pour les transferts et restaurations. Chaque serveur correspond a un fichier `config/remotes/<nom>.conf`.

Sous-commandes :

- `remote list` : liste les serveurs connus (le serveur par defaut est marque d une `*`).
- `remote add <nom> --host <hote> --user <utilisateur> [options]` : cree un nouveau profil. Options disponibles : `--port`, `--path`, `--auth key|password`, `--ssh-key`, `--password`, `--verify yes|no`, `--delete-after yes|no`, `--set-default`.
- `remote show <nom>` : affiche la configuration detaillee.
- `remote remove <nom>` : supprime le profil (et reinitialise le defaut si besoin).
- `remote set-default <nom>` : definit le serveur utilise par defaut quand `--remote` n est pas renseigne.
- `remote test <nom>` : tente une connexion SSH/SFTP avec les parametres stockes.

Exemples :

```bash
# Ajouter un serveur distant base sur une cle SSH
./dbbackup remote add prod --host backup.example.com --user backup --auth key --ssh-key ~/.ssh/id_rsa --path /srv/backups --set-default

# Afficher la configuration puis tester la connexion
./dbbackup remote show prod
./dbbackup remote test prod
```

### `dbbackup config show`

Affiche le contenu de `config/dbbackup.conf`, le resume des transferts (`config/transfer.conf`), la liste des serveurs distants disponibles et les chemins importants (cle de chiffrement, fichier de planification). Utile pour verifier rapidement la configuration active.

Exemple :

```bash
./dbbackup config show
```

## Fichiers et dossiers importants

- `dbbackup` : point d entree CLI.
- `lib/` : modules Bash responsables des sauvegardes, restaurations, transferts, chiffrement, planification et configuration.
- `config/dbbackup.conf` : parametres par defaut (hote, port, dossier de sauvegarde, retention, logs).
- `config/encryption.key` : cle AES-256 utilisee pour le chiffrement.
- `config/transfer.conf` et `config/remotes/*.conf` : definition des serveurs distants et du serveur par defaut.
- `config/schedules.conf` : liste des planifications cron gerees par l outil.
- `backups/` : destination locale des sauvegardes (avant transfert).
- `logs/` : journaux d execution et historiques de taches cron.

## Bonnes pratiques

- Verifiez regulierement les sauvegardes avec `dbbackup restore --verify`.
- Conservez les clefs SSH et `config/encryption.key` en lieu sur et avec les bonnes permissions.
- Surveillez le dossier `logs/` pour confirmer la reussite des sauvegardes planifiees.
- Utilisez `dbbackup remote test` apres toute modification d infrastructure distante.
