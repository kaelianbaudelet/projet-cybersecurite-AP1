#!/bin/bash
# backup.sh

# ============================================================================
# Module de Sauvegarde
# ============================================================================
# Gère les opérations de sauvegarde de base de données incluant dump, compression et nettoyage
# ============================================================================

print_backup_table_header() {
    printf "%-31s%-27s%s\n" 'NOM' 'DATE DE CRÉATION' ' FICHIER'
    printf "%-31s%-27s%s\n" '-------------------------------' '---------------------------' '-----------------------------------'
}
print_backup_table_row() {
    local name="$1" created="$2" file="$3"
    printf "%-31s%-27s%s\n" "${name}" "${created}" "${file}"
}

# Déduit le nom logique d'une sauvegarde à partir de son fichier
backup_display_name() {
    local file="$1"
    local name="${file}"
    if [[ "${name}" == *.sql.gz.enc ]]; then
        name="${name%.sql.gz.enc}"
    elif [[ "${name}" == *.sql.gz ]]; then
        name="${name%.sql.gz}"
    elif [[ "${name}" == *.sql ]]; then
        name="${name%.sql}"
    fi
    echo "${name}"
}

# Formatte la date de modification d'un fichier local
backup_format_local_mtime() {
    local file="$1"
    if date -r "${file}" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
        date -r "${file}" "+%Y-%m-%d %H:%M:%S"
    elif stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${file}" >/dev/null 2>&1; then
        stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${file}"
    elif stat -c "%y" "${file}" >/dev/null 2>&1; then
        stat -c "%y" "${file}" | cut -d'.' -f1
    else
        echo "Inconnue"
    fi
}

# ============================================================================
# Effectuer une sauvegarde de base de données
# ============================================================================
perform_backup() {
    local db_host="$1"
    local db_port="$2"
    local db_user="$3"
    local db_password="$4"
    local db_name="$5"
    local output_dir="$6"
    local enable_encryption="${7:-yes}"
    local enable_transfer="${8:-yes}"
    local remote_server="${9:-}"
    local resolved_remote=""

    log_info "Démarrage de la sauvegarde pour la base de données : ${db_name}"

    # Générer le nom de fichier de sauvegarde avec horodatage
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_filename="${db_name}_${timestamp}.sql"
    local backup_path="${output_dir}/${backup_filename}"

    # Créer le répertoire de sortie (toujours pour stockage temporaire)
    mkdir -p "${output_dir}"

    # Étape 1 : Créer le dump de la base de données
    log_info "Création du dump de la base de données..."
    if ! create_dump "${db_host}" "${db_port}" "${db_user}" "${db_password}" "${db_name}" "${backup_path}"; then
        log_error "Échec de la création du dump de la base de données"
        return 1
    fi

    # Étape 2 : Compresser la sauvegarde
    log_info "Compression de la sauvegarde..."
    if ! compress_backup "${backup_path}"; then
        log_error "Échec de la compression de la sauvegarde"
        rm -f "${backup_path}"
        return 1
    fi
    local compressed_file="${backup_path}.gz"

    # Étape 3 : Chiffrer la sauvegarde (si activé)
    local final_file="${compressed_file}"
    local checksum_file

    if [[ "${enable_encryption}" == "yes" ]]; then
        log_info "Chiffrement de la sauvegarde..."
        if ! encrypt_file "${compressed_file}"; then
            log_error "Échec du chiffrement de la sauvegarde"
            rm -f "${backup_path}" "${compressed_file}"
            return 1
        fi
        final_file="${compressed_file}.enc"

        # Etape 4 : Généré une somme d'intégrité
        log_info "Génération de la somme de contrôle d'intégrité..."
        checksum_file=$(generate_checksum "${final_file}")
        if [[ -z "${checksum_file}" ]]; then
            log_error "Échec de la génération de la somme de contrôle"
            rm -f "${backup_path}" "${compressed_file}" "${final_file}"
            return 1
        fi
    else
        # Etape 4 : Généré une somme d'intégrité
        log_info "Génération de la somme de contrôle d'intégrité..."
        checksum_file=$(generate_checksum "${compressed_file}")
        if [[ -z "${checksum_file}" ]]; then
            log_error "Échec de la génération de la somme de contrôle"
            rm -f "${backup_path}" "${compressed_file}"
            return 1
        fi
    fi

    if [[ "${enable_transfer}" == "yes" ]]; then
        resolved_remote="${remote_server:-${DEFAULT_REMOTE_SERVER:-}}"
        if [[ -z "${resolved_remote}" ]]; then
            log_error "Transfert distant demandé mais aucun serveur distant n'est défini."
            log_info "Utilisez '--remote <nom>' ou 'dbbackup remote set-default <nom>'."
            rm -f "${backup_path}" "${compressed_file}" "${compressed_file}.sha256" "${final_file}" "${checksum_file}"
            return 1
        fi

        if ! use_remote_server "${resolved_remote}"; then
            rm -f "${backup_path}" "${compressed_file}" "${compressed_file}.sha256" "${final_file}" "${checksum_file}"
            return 1
        fi

        resolved_remote="${ACTIVE_REMOTE_NAME}"
        log_info "Transfert de la sauvegarde vers le serveur distant '${resolved_remote}'..."

        if [[ "${KEEP_CHECKSUMS_AFTER_BACKUP}" == "yes" ]]; then
            if ! transfer_file "${final_file}" "${checksum_file}"; then
                log_warning "Échec du transfert de la sauvegarde vers le serveur distant"
                log_info "La sauvegarde n'est pas disponible localement non plus (mode distant)"
            else
                log_success "Sauvegarde transférée avec succès vers '${resolved_remote}'"
                log_info "Suppression des fichiers locaux après transfert distant réussi..."
            fi
        else
            if ! transfer_file "${final_file}"; then
                log_warning "Échec du transfert de la sauvegarde vers le serveur distant"
                log_info "La sauvegarde n'est pas disponible localement non plus (mode distant)"
            else
                log_success "Sauvegarde transférée avec succès vers '${resolved_remote}'"
                log_info "Suppression des fichiers locaux après transfert distant réussi..."
            fi
        fi

        if [[ "${KEEP_CHECKSUMS_AFTER_BACKUP}" == "yes" ]]; then
            rm -f "${backup_path}" "${compressed_file}" "${compressed_file}.sha256" "${final_file}" "${checksum_file}"
        else
            rm -f "${backup_path}" "${compressed_file}" "${compressed_file}.sha256" "${final_file}" "${checksum_file}"

            if [[ -n "${checksum_file}" && -f "${checksum_file}" ]]; then
                rm -f "${checksum_file}"
            fi
        fi

        cleanup_remote_backups

        log_success "Sauvegarde distante terminée, fichier envoyé vers ${resolved_remote}"
        echo "La sauvegarde a été transférée vers '${resolved_remote}'."
    else
        cleanup_old_backups "${output_dir}"
        rm -f "${backup_path}"
        if [[ "${enable_encryption}" == "yes" ]]; then
            rm -f "${compressed_file}"
        fi

        log_success "Sauvegarde local terminée, fichier enregistré dans ${final_file}"
        echo "La sauvegarde à été créer localement."
        
        echo "Fichier de sauvegarde : ${final_file}"

        if [[ "${KEEP_CHECKSUMS_AFTER_BACKUP}" != "yes" ]]; then
            rm -f "${checksum_file}"
        else
            echo "Fichier de somme de contrôle : ${checksum_file}"
        fi

    fi

    return 0
}

# ============================================================================
# Créer un dump de base de données avec mysqldump
# ============================================================================
create_dump() {
    local db_host="$1"
    local db_port="$2"
    local db_user="$3"
    local db_password="$4"
    local db_name="$5"
    local output_file="$6"

    # Vérifier si mysqldump est disponible
    if ! command -v mysqldump &> /dev/null; then
        log_error "Commande mysqldump introuvable. Veuillez installer le client MariaDB/MySQL."
        return 1
    fi

    # Créer le dump avec les options :
    # --single-transaction : assure la cohérence sans verrouiller les tables
    # --quick : récupère les lignes une par une
    # --lock-tables=false : ne verrouille pas les tables
    # --routines : inclut les procédures stockées et les fonctions
    # --triggers : inclut les déclencheurs
    # --events : inclut les événements
    MYSQL_PWD="${db_password}" mysqldump \
        --host="${db_host}" \
        --port="${db_port}" \
        --user="${db_user}" \
        --ssl-verify-server-cert=0 \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --routines \
        --triggers \
        --events \
        "${db_name}" > "${output_file}" 2>> "${log_file}"

    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        if [[ ${exit_code} -eq 2 ]]; then
            log_error "La base de données est injoignable ou les identifiants sont incorrects."
        else
            log_error "mysqldump a échoué avec le code de sortie ${exit_code}"
        fi
        return 1
    fi

    # Vérifier que le fichier dump a été créé et contient des données
    if [[ ! -s "${output_file}" ]]; then
        log_error "Le fichier dump est vide ou n'a pas été créé"
        return 1
    fi

    local file_size=$(du -h "${output_file}" | cut -f1)
    log_info "Dump de la base de données créé : ${output_file} (${file_size})"

    return 0
}

# ============================================================================
# Compresser un fichier de sauvegarde avec gzip
# ============================================================================
compress_backup() {
    local file_path="$1"

    if [[ ! -f "${file_path}" ]]; then
        log_error "Fichier introuvable : ${file_path}"
        return 1
    fi

    gzip -f "${file_path}" 2>> "${log_file}"

    if [[ $? -ne 0 ]]; then
        log_error "Échec de la compression du fichier : ${file_path}"
        return 1
    fi

    local compressed_size=$(du -h "${file_path}.gz" | cut -f1)
    log_info "Fichier compressé : ${file_path}.gz (${compressed_size})"

    return 0
}

# ============================================================================
# Générer une somme de contrôle SHA256
# ============================================================================
generate_checksum() {
    local file_path="$1"

    if [[ ! -f "${file_path}" ]]; then
        log_error "Fichier introuvable pour la somme de contrôle : ${file_path}"
        return 1
    fi

    local checksum_file="${file_path}.sha256"

    # Utiliser la commande sha256 appropriée selon l'OS
    if command -v shasum &> /dev/null; then
        shasum -a 256 "${file_path}" > "${checksum_file}"
    elif command -v sha256sum &> /dev/null; then
        sha256sum "${file_path}" > "${checksum_file}"
    else
        log_error "Aucune commande SHA256 trouvée (shasum ou sha256sum)"
        return 1
    fi

    log_info "Somme de contrôle générée : ${checksum_file}" >&2
    echo "${checksum_file}"

    return 0
}

# ============================================================================
# Vérifier la somme de contrôle
# ============================================================================
verify_checksum() {
    local file_path="$1"
    local checksum_file="${file_path}.sha256"

    if [[ ! -f "${checksum_file}" ]]; then
        log_error "Fichier de somme de contrôle introuvable : ${checksum_file}"
        return 1
    fi

    log_info "Vérification de l'intégrité..."

    local expected_checksum=$(cat "${checksum_file}" | awk '{print $1}')

    local actual_checksum
    if command -v shasum &> /dev/null; then
        actual_checksum=$(shasum -a 256 "${file_path}" | awk '{print $1}')
    elif command -v sha256sum &> /dev/null; then
        actual_checksum=$(sha256sum "${file_path}" | awk '{print $1}')
    else
        log_error "Aucune commande SHA256 trouvée"
        return 1
    fi

    if [[ "${expected_checksum}" == "${actual_checksum}" ]]; then
        log_success "Vérification de l'intégrité réussie"
        return 0
    else
        log_error "Échec de la vérification de l'intégrité !"
        log_error "Attendue : ${expected_checksum}"
        log_error "Réelle : ${actual_checksum}"
        return 1
    fi
}

# ============================================================================
# Nettoyer les anciennes sauvegardes selon la politique de rétention
# ============================================================================
cleanup_old_backups() {
    local backup_dir="$1"
    local retention_days="${BACKUP_RETENTION_DAYS:-7}"

    log_info "Nettoyage des sauvegardes de plus de ${retention_days} jours..."

    # Trouver et supprimer les anciens fichiers de sauvegarde
    local deleted_count=0
    while IFS= read -r -d '' file; do
        rm -f "${file}"
        rm -f "${file}.sha256"
        ((deleted_count++))
        log_info "Ancienne sauvegarde supprimée : $(basename "${file}")"
    done < <(find "${backup_dir}" -name "*.sql.gz*" -type f -mtime +${retention_days} -print0 2>/dev/null)

    if [[ ${deleted_count} -gt 0 ]]; then
        log_info "Nettoyage de ${deleted_count} ancienne(s) sauvegarde(s) effectué"
    else
        log_info "Aucune sauvegarde à nettoyer (rétention ${retention_days} jours)"
    fi
}

# ============================================================================
# Nettoyer les anciennes sauvegardes selon la politique de rétention
# ============================================================================

# ============================================================================
# Nettoyer les anciennes sauvegardes DISTANTES
# ============================================================================
cleanup_remote_backups() {
    local remote_name="${1:-${DEFAULT_REMOTE_SERVER}}"
    local retention_days="${BACKUP_RETENTION_DAYS:-7}"
    local deleted_count=0

    # --- config serveur distant ---
    if ! use_remote_server "${remote_name}"; then
        log_error "Impossible de charger le serveur distant '${remote_name}'"
        return 1
    fi

    # --- test connexion ---
    if ! test_remote_connection > /dev/null 2>&1; then
        log_error "Serveur distant injoignable (${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT})"
        return 1
    fi

    log_info "Nettoyage des sauvegardes de plus de ${retention_days} jours..."

    # --- commande complète exécutée sur le remote ---
    local remote_script=$(cat <<'EOF'
retention_days=__RETENTION__
path="__PATH__"
deleted=0
while IFS= read -r -d '' f; do
    rm -f "$f" "$f.sha256"
    echo "DELETED:$(basename "$f")"
    ((deleted++))
done < <(find "$path" -name '*.sql.gz*' -type f -mtime +$retention_days -print0 2>/dev/null)
echo "COUNT:$deleted"
EOF
)

    remote_script="${remote_script//__RETENTION__/$retention_days}"
    remote_script="${remote_script//__PATH__/$REMOTE_PATH}"

    # --- exécution selon méthode d’auth ---
    local output
    if [[ "${REMOTE_AUTH_METHOD}" == "key" ]]; then
        output=$(ssh -p "${REMOTE_PORT}" -i "${REMOTE_SSH_KEY}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${REMOTE_USER}@${REMOTE_HOST}" "$remote_script" 2>>"${log_file}")
    else
        output=$(sshpass -p "${REMOTE_PASSWORD}" ssh -p "${REMOTE_PORT}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${REMOTE_USER}@${REMOTE_HOST}" "$remote_script" 2>>"${log_file}")
    fi

    while IFS= read -r line; do
        case "$line" in
            DELETED:*) log_info "Ancienne sauvegarde distante supprimée : ${line#DELETED:}" ;;
            COUNT:*)   deleted_count="${line#COUNT:}" ;;
        esac
    done <<< "$output"

    if [[ ${deleted_count} -gt 0 ]]; then
        log_info "Nettoyage de ${deleted_count} ancienne(s) sauvegarde(s) distante(s) effectué"
    else
        log_info "Aucune sauvegarde distante à nettoyer (rétention ${retention_days} jours)"
    fi

    return 0
}

backup_show_help() {
    cat << EOF
Gestion de la sauvegarde :

    dbbackup backup [options]
        Effectuer une sauvegarde locale ou distante d'une base de données MariaDB/MySQL.

        Options :
            -h, --host <hôte>            Hôte de la base de données (défaut : localhost)
            -P, --port <port>            Port de la base de données (défaut : 3306)
            -u, --user <utilisateur>     Utilisateur de la base de données (obligatoire)
            -p, --password <mot_de_passe> Mot de passe de la base de données (obligatoire)
            -d, --database <nom>         Nom de la base de données à sauvegarder (obligatoire)
            -o, --output <répertoire>    Répertoire de sortie pour la sauvegarde (défaut : BACKUP_DIR)
            --encrypt                    Activer le chiffrement de la sauvegarde (défaut : activé)
            --no-encrypt                 Désactiver le chiffrement de la sauvegarde
            --transfer                   Activer le transfert vers un serveur distant (nécessite configuration)
            --no-transfer                Désactiver le transfert distant (défaut)
            --remote|--remote-server <nom> Spécifier le serveur distant pour le transfert (optionnel)
            -h, --help                   Afficher cette aide

    dbbackup backup list [options]
        Lister les sauvegardes locales ou distantes disponibles.

        Options :
            -o, --output <dir>        Répertoire local contenant les sauvegardes (défaut : BACKUP_DIR)
            --remote[=nom]            Lister uniquement les sauvegardes distantes. Utilise le serveur par défaut si le nom est omis.

Exemples :
    # Sauvegarde locale d'une base nommée mydb
    dbbackup backup -u root -p secret -d mydb

    # Sauvegarde avec chiffrement désactivé
    dbbackup backup -u admin -p passwd -d production --no-encrypt

    # Sauvegarde vers un serveur distant nommé "prod-remote"
    dbbackup backup -u user -p pass -d sales --transfer --remote prod-remote

    # Lister les sauvegardes locales
    dbbackup backup list

    # Lister les sauvegardes distantes sur "prod-remote"
    dbbackup backup list --remote=prod-remote

EOF
}

# ============================================================================
# Commande : sauvegarde
# ============================================================================
cmd_backup() {
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-3306}"
    local db_user=""
    local db_password=""
    local db_name=""
    local output_dir="${BACKUP_DIR}"
    local enable_encryption="${ENCRYPTION:-yes}"
    local enable_transfer="${TRANSFER:-no}"
    local remote_server=""

    if [[ $# -gt 0 && "$1" == "list" ]]; then
        shift
        cmd_backup_list "$@"
        return
    fi

    # Analyser les arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--host)
                db_host="$2"
                shift 2
                ;;
            -P|--port)
                db_port="$2"
                shift 2
                ;;
            -u|--user)
                db_user="$2"
                shift 2
                ;;
            -p|--password)
                db_password="$2"
                shift 2
                ;;
            -d|--database)
                db_name="$2"
                shift 2
                ;;
            -o|--output)
                output_dir="$2"
                shift 2
                ;;
            --encrypt)
                enable_encryption="yes"
                shift
                ;;
            --no-encrypt)
                enable_encryption="no"
                shift
                ;;
            --transfer)
                enable_transfer="yes"
                shift
                ;;
            --no-transfer)
                enable_transfer="no"
                shift
                ;;
            --remote|--remote-server)
                remote_server="$2"
                enable_transfer="yes"
                shift 2
                ;;
            help|--help)
                backup_show_help
                exit 0
                ;;
            *)
                echo "Erreur : Option inconnue '$1'"
                backup_show_help
                exit 1
                ;;
        esac
    done

    # Valider les paramètres requis
    if [[ -z "${db_user}" ]]; then
        echo "Erreur : L'utilisateur de la base de données est requis (-u ou --user)"
        exit 1
    fi

    if [[ -z "${db_password}" ]]; then
        echo "Erreur : Le mot de passe de la base de données est requis (-p ou --password)"
        exit 1
    fi

    if [[ -z "${db_name}" ]]; then
        echo "Erreur : Le nom de la base de données est requis (-d ou --database)"
        exit 1
    fi

    # Effectuer la sauvegarde
    if perform_backup "${db_host}" "${db_port}" "${db_user}" "${db_password}" \
                      "${db_name}" "${output_dir}" "${enable_encryption}" "${enable_transfer}" \
                      "${remote_server}"; then
        exit 0
    else
        exit 1
    fi
}

# ============================================================================
# Commande : lister les sauvegardes
# ============================================================================

cmd_backup_list() {
    local output_dir="${BACKUP_DIR}"
    local remote_requested="no"
    local remote_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                if [[ -z "${2:-}" ]]; then
                    echo "Erreur : '--output' requiert un argument"
                    exit 1
                fi
                output_dir="$2"
                shift 2
                ;;
            --remote)
                remote_requested="yes"
                if [[ $# -ge 2 && "${2}" != --* && "${2}" != -* ]]; then
                    remote_name="$2"
                    shift 2
                else
                    shift 1
                fi
                ;;
            --remote=*)
                remote_requested="yes"
                remote_name="${1#*=}"
                shift
                ;;
            -h|--help)
                cat << EOF
Usage : dbbackup backup list [options]

Options :
    -o, --output <dir>    Répertoire local contenant les sauvegardes (défaut : BACKUP_DIR)
    --remote[=nom]        Lister uniquement les sauvegardes distantes. Utilise le serveur par défaut si le nom est omis.
EOF
                return
                ;;
            *)
                echo "Erreur : Option inconnue '$1'"
                exit 1
                ;;
        esac
    done

    # Si --remote est spécifié, on affiche UNIQUEMENT les sauvegardes distantes
    if [[ "${remote_requested}" == "yes" ]]; then
        local resolved_remote="${remote_name}"
        if [[ -z "${resolved_remote}" ]]; then
            if [[ -n "${DEFAULT_REMOTE_SERVER:-}" ]]; then
                resolved_remote="${DEFAULT_REMOTE_SERVER}"
            else
                echo "Erreur : aucun serveur distant par défaut n'est configuré. Utilisez '--remote <nom>' ou configurez un serveur distant par défaut."
                exit 1
            fi
        fi

        if ! use_remote_server "${resolved_remote}"; then
            exit 1
        fi

        if ! test_remote_connection > /dev/null 2>&1; then
            echo "Erreur : Hôte distant injoignable (${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT})"
            echo "Vérifiez votre connexion réseau et la configuration du serveur distant."
            exit 1
        fi

        echo ""
        echo "Sauvegardes distantes pour '${ACTIVE_REMOTE_NAME}' (${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}) :"
        list_remote_backups
        return
    fi

    # Sinon, affichage des sauvegardes locales uniquement
    if [[ -z "${output_dir}" ]]; then
        output_dir="${BACKUP_DIR}"
    fi

    if [[ ! -d "${output_dir}" ]]; then
        echo "Erreur : Répertoire introuvable : ${output_dir}"
        exit 1
    fi

    local -a backup_files=()
    while IFS= read -r file; do
        backup_files+=("$file")
    done < <(find "${output_dir}" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.sql.gz.enc' \) -print | sort)

    local -a seen_local=()
    local -a local_rows=()
    local file_path
    if (( ${#backup_files[@]} > 0 )); then
        for file_path in "${backup_files[@]}"; do
            local file_name
            file_name=$(basename "${file_path}")
            local duplicate="no"
            if (( ${#seen_local[@]} > 0 )); then
                local existing
                for existing in "${seen_local[@]}"; do
                    if [[ "${existing}" == "${file_name}" ]]; then
                        duplicate="yes"
                        break
                    fi
                done
            fi
            if [[ "${duplicate}" == "yes" ]]; then
                continue
            fi
            seen_local+=("${file_name}")
            local created
            created=$(backup_format_local_mtime "${file_path}")
            local display_name
            display_name=$(backup_display_name "${file_name}")
            local_rows+=("${display_name}|${created}|${file_name}")
        done
    fi

    if (( ${#local_rows[@]} == 0 )); then
        echo "Aucune sauvegarde locale trouvée dans ${output_dir}"
    else
        echo "Sauvegardes locales dans ${output_dir} :"
        print_backup_table_header
        local row
        for row in "${local_rows[@]}"; do
            local local_name
            local local_created
            local local_file
            IFS='|' read -r local_name local_created local_file <<< "${row}"
            print_backup_table_row "${local_name}" "${local_created}" "${local_file}"
        done
    fi
}