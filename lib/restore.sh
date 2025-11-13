#!/bin/bash

# ============================================================================
# Module de Restauration
# ============================================================================
# Gère la restauration de base de données depuis des fichiers de sauvegarde chiffrés
# ============================================================================

# ============================================================================
# Restaurer une base de données depuis une sauvegarde
# ============================================================================
perform_restore() {
    local backup_file="$1"
    local db_host="$2"
    local db_port="$3"
    local db_user="$4"
    local db_password="$5"
    local db_name="$6"

    log_info "Démarrage de la restauration pour la base de données : ${db_name}"

    if [[ ! -f "${backup_file}" ]]; then
        log_error "Fichier de sauvegarde introuvable : ${backup_file}"
        return 1
    fi

    # Déterminer le type de fichier et les étapes de traitement
    local temp_dir=$(mktemp -d)
    local working_file="${backup_file}"
    local cleanup_files=()

    # Étape 1 : Déchiffrer si chiffré
    if is_encrypted "${backup_file}"; then
        log_info "Déchiffrement du fichier de sauvegarde..."
        local decrypted_file="${temp_dir}/decrypted.sql.gz"
        if ! decrypt_file "${backup_file}" "${decrypted_file}"; then
            log_error "Échec du déchiffrement du fichier de sauvegarde"
            rm -rf "${temp_dir}"
            return 1
        fi
        working_file="${decrypted_file}"
        cleanup_files+=("${decrypted_file}")
    fi

    # Étape 2 : Vérifier l'intégrité si la somme de contrôle existe
    local checksum_file="${backup_file}.sha256"
    if [[ -f "${checksum_file}" ]]; then
        log_info "Vérification de l'intégrité de la sauvegarde..."
        if ! verify_checksum "${backup_file}"; then
            log_warning "Échec de la vérification de l'intégrité. Continuer quand même ? (y/n)"
            read -r response
            if [[ "${response}" != "y" ]]; then
                log_error "Restauration annulée"
                rm -rf "${temp_dir}"
                return 1
            fi
        fi
    fi

    # Étape 3 : Décompresser si compressé avec gzip
    local sql_file="${working_file}"
    if [[ "${working_file}" == *.gz ]]; then
        log_info "Décompression du fichier de sauvegarde..."
        local decompressed_file="${temp_dir}/backup.sql"
        if ! decompress_backup "${working_file}" "${decompressed_file}"; then
            log_error "Échec de la décompression du fichier de sauvegarde"
            rm -rf "${temp_dir}"
            return 1
        fi
        sql_file="${decompressed_file}"
        cleanup_files+=("${decompressed_file}")
    fi

    # Étape 4 : Restaurer vers la base de données
    log_info "Restauration de la base de données..."
    if ! restore_to_database "${sql_file}" "${db_host}" "${db_port}" \
                             "${db_user}" "${db_password}" "${db_name}"; then
        log_error "Échec de la restauration de la base de données"
        rm -rf "${temp_dir}"
        return 1
    fi

    # Nettoyage des fichiers temporaires
    rm -rf "${temp_dir}"

    log_success "Restauration de la base de données terminée avec succès"
    return 0
}

# ============================================================================
# Décompresser un fichier de sauvegarde
# ============================================================================
decompress_backup() {
    local input_file="$1"
    local output_file="$2"

    if [[ ! -f "${input_file}" ]]; then
        log_error "Fichier d'entrée introuvable : ${input_file}"
        return 1
    fi

    gunzip -c "${input_file}" > "${output_file}" 2>> "${log_file}"

    if [[ $? -ne 0 ]]; then
        log_error "Échec de la décompression du fichier"
        return 1
    fi

    if [[ ! -s "${output_file}" ]]; then
        log_error "Le fichier décompressé est vide"
        return 1
    fi

    local file_size=$(du -h "${output_file}" | cut -f1)
    log_info "Fichier décompressé : ${output_file} (${file_size})"

    return 0
}

# ============================================================================
# Restaurer un fichier SQL vers la base de données
# ============================================================================
restore_to_database() {
    local sql_file="$1"
    local db_host="$2"
    local db_port="$3"
    local db_user="$4"
    local db_password="$5"
    local db_name="$6"

    if [[ ! -f "${sql_file}" ]]; then
        log_error "Fichier SQL introuvable : ${sql_file}"
        return 1
    fi

    # Vérifier si le client mysql est disponible
    if ! command -v mysql &> /dev/null; then
        log_error "Commande mysql introuvable. Veuillez installer le client MariaDB/MySQL."
        return 1
    fi

    # Vérifier si la base de données existe
    log_info "Vérification de l'existence de la base de données '${db_name}'..."
    if ! database_exists "${db_host}" "${db_port}" "${db_user}" "${db_password}" "${db_name}"; then
        log_warning "La base de données '${db_name}' n'existe pas"
        log_info "Créer la base de données ? (y/n)"
        read -r response
        if [[ "${response}" == "y" ]]; then
            if ! create_database "${db_host}" "${db_port}" "${db_user}" "${db_password}" "${db_name}"; then
                log_error "Échec de la création de la base de données"
                return 1
            fi
        else
            log_error "Impossible de restaurer vers une base de données inexistante"
            return 1
        fi
    fi

    # Confirmer la restauration
    log_warning "ATTENTION : Cela écrasera la base de données existante '${db_name}'"
    log_warning "Voulez-vous continuer ? (yes/no)"
    read -r response
    if [[ "${response}" != "yes" ]]; then
        log_error "Restauration annulée"
        return 1
    fi

    # Restaurer la base de données
    log_info "Restauration vers la base de données '${db_name}'..."
    MYSQL_PWD="${db_password}" mysql \
        --host="${db_host}" \
        --port="${db_port}" \
        --user="${db_user}" \
        "${db_name}" < "${sql_file}" 2>> "${log_file}"

    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "La restauration mysql a échoué avec le code de sortie ${exit_code}"
        return 1
    fi

    log_success "Base de données restaurée avec succès"
    return 0
}

# ============================================================================
# Vérifier si une base de données existe
# ============================================================================
database_exists() {
    local db_host="$1"
    local db_port="$2"
    local db_user="$3"
    local db_password="$4"
    local db_name="$5"

    MYSQL_PWD="${db_password}" mysql \
        --host="${db_host}" \
        --port="${db_port}" \
        --user="${db_user}" \
        -e "USE ${db_name}" 2>/dev/null

    return $?
}

# ============================================================================
# Créer une base de données
# ============================================================================
create_database() {
    local db_host="$1"
    local db_port="$2"
    local db_user="$3"
    local db_password="$4"
    local db_name="$5"

    log_info "Création de la base de données '${db_name}'..."

    MYSQL_PWD="${db_password}" mysql \
        --host="${db_host}" \
        --port="${db_port}" \
        --user="${db_user}" \
        -e "CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>> "${log_file}"

    if [[ $? -ne 0 ]]; then
        log_error "Échec de la création de la base de données"
        return 1
    fi

    log_success "Base de données '${db_name}' créée"
    return 0
}

# ============================================================================
# Restaurer depuis une sauvegarde distante
# ============================================================================
restore_from_remote() {
    local remote_file="$1"
    local db_host="$2"
    local db_port="$3"
    local db_user="$4"
    local db_password="$5"
    local db_name="$6"

    log_info "Restauration depuis la sauvegarde distante : ${remote_file}"

    # Télécharger la sauvegarde depuis le serveur distant
    local temp_dir=$(mktemp -d)
    local local_backup="${temp_dir}/$(basename "${remote_file}")"

    if ! download_file "${remote_file}" "${local_backup}"; then
        log_error "Échec du téléchargement de la sauvegarde depuis le serveur distant"
        rm -rf "${temp_dir}"
        return 1
    fi

    # Télécharger la somme de contrôle si elle existe
    local remote_checksum="${remote_file}.sha256"
    local local_checksum="${local_backup}.sha256"
    download_file "${remote_checksum}" "${local_checksum}" 2>/dev/null || true

    # Restaurer depuis le fichier téléchargé
    if perform_restore "${local_backup}" "${db_host}" "${db_port}" \
                      "${db_user}" "${db_password}" "${db_name}"; then
        rm -rf "${temp_dir}"
        return 0
    else
        rm -rf "${temp_dir}"
        return 1
    fi
}

# ============================================================================
# Lister les sauvegardes disponibles pour la restauration
# ============================================================================
list_available_backups() {
    local backup_dir="${BACKUP_DIR}"

    echo "Sauvegardes Locales Disponibles :"
    echo "========================"

    if [[ -d "${backup_dir}" ]]; then
        local found=0
        while IFS= read -r -d '' file; do
            local filename=$(basename "${file}")
            local filesize=$(du -h "${file}" | cut -f1)
            local filedate=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${file}" 2>/dev/null || stat -c "%y" "${file}" 2>/dev/null | cut -d'.' -f1)
            printf "%-50s %10s  %s\n" "${filename}" "${filesize}" "${filedate}"
            found=1
        done < <(find "${backup_dir}" -name "*.sql.gz*" -type f ! -name "*.sha256" -print0 2>/dev/null | sort -z)

        if [[ ${found} -eq 0 ]]; then
            echo "Aucune sauvegarde locale trouvée"
        fi
    else
        echo "Répertoire de sauvegarde introuvable : ${backup_dir}"
    fi

    echo ""
}

# ============================================================================
# Vérifier un fichier de sauvegarde avant restauration
# ============================================================================
verify_backup() {
    local backup_file="$1"

    log_info "Vérification du fichier de sauvegarde : ${backup_file}"

    if [[ ! -f "${backup_file}" ]]; then
        log_error "Fichier de sauvegarde introuvable"
        return 1
    fi

    # Vérifier la taille du fichier
    local file_size=$(stat -f "%z" "${backup_file}" 2>/dev/null || stat -c "%s" "${backup_file}" 2>/dev/null)
    if [[ ${file_size} -eq 0 ]]; then
        log_error "Le fichier de sauvegarde est vide"
        return 1
    fi

    log_info "Taille du fichier : $(du -h "${backup_file}" | cut -f1)"

    # Vérifier l'intégrité si la somme de contrôle existe
    local checksum_file="${backup_file}.sha256"
    if [[ -f "${checksum_file}" ]]; then
        if verify_checksum "${backup_file}"; then
            log_success "Vérification de l'intégrité réussie"
        else
            log_error "Échec de la vérification de l'intégrité"
            return 1
        fi
    else
        log_warning "Aucun fichier de somme de contrôle trouvé pour la vérification de l'intégrité"
    fi

    # Vérifier si le fichier est chiffré
    if is_encrypted "${backup_file}"; then
        log_info "La sauvegarde est chiffrée : oui"
    else
        log_info "La sauvegarde est chiffrée : non"
    fi

    log_success "Vérification de la sauvegarde terminée"
    return 0
}

restore_show_help() {
    cat << EOF
Gestion de la restauration :

    dbbackup restore [options]
        Restaurer une base de données à partir d'un fichier de sauvegarde.

        Options :
            -f, --file <fichier>            Fichier de sauvegarde à restaurer (obligatoire)
            -h, --host <hôte>               Hôte de la base de données cible (défaut : localhost)
            -P, --port <port>               Port de la base de données cible (défaut : 3306)
            -u, --user <utilisateur>        Utilisateur de la base de données (obligatoire)
            -p, --password <mot_de_passe>   Mot de passe de la base de données (obligatoire)
            -d, --database <nom>            Nom de la base de données cible (obligatoire)
            --remote                        Restaurer depuis une sauvegarde distante (serveur distant)
            --verify                        Vérifier le fichier de sauvegarde uniquement (aucune restauration)
            --list                          Lister les sauvegardes locales disponibles

Exemples :
    # Restaurer une base de données depuis une sauvegarde locale
    dbbackup restore -f backup.sql.gz.enc -u root -p secret -d mydb

    # Vérifier une sauvegarde sans restaurer
    dbbackup restore -f backup.sql.gz.enc --verify

    # Lister les sauvegardes locales disponibles
    dbbackup restore --list

    # Restaurer une base de données depuis un serveur distant
    dbbackup restore -f daily/mydb-2024-05-10.sql.gz.enc --remote -u root -p secret -d mydb

EOF
}

# ============================================================================
# Commande : restaurer
# ============================================================================
cmd_restore() {
    local backup_file=""
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-3306}"
    local db_user=""
    local db_password=""
    local db_name=""
    local from_remote="no"
    local verify_only="no"

    # Analyser les arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                backup_file="$2"
                shift 2
                ;;
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
            --remote)
                from_remote="yes"
                shift
                ;;
            --verify)
                verify_only="yes"
                shift
                ;;
            --list)
                list_available_backups
                exit 0
                ;;
            help|-h|--help)
                restore_show_help
                exit 0
                ;;
            *)
                echo "Erreur : Option inconnue '$1'"
                restore_show_help
                exit 1
                ;;
        esac
    done

    if [[ -z "${backup_file}" ]]; then
        echo "Erreur : Le fichier de sauvegarde est requis (-f ou --file)"
        echo "Utilisez --list pour voir les sauvegardes disponibles"
        restore_show_help
        exit 1
    fi

    # Si vérification uniquement
    if [[ "${verify_only}" == "yes" ]]; then
        if verify_backup "${backup_file}"; then
            exit 0
        else
            exit 1
        fi
    fi

    # Valider les paramètres de la base de données
    if [[ -z "${db_user}" ]]; then
        echo "Erreur : L'utilisateur de la base de données est requis (-u ou --user)"
        restore_show_help
        exit 1
    fi

    if [[ -z "${db_password}" ]]; then
        echo "Erreur : Le mot de passe de la base de données est requis (-p ou --password)"
        restore_show_help
        exit 1
    fi

    if [[ -z "${db_name}" ]]; then
        echo "Erreur : Le nom de la base de données est requis (-d ou --database)"
        restore_show_help
        exit 1
    fi

    # Effectuer la restauration
    if [[ "${from_remote}" == "yes" ]]; then
        if restore_from_remote "${backup_file}" "${db_host}" "${db_port}" \
                              "${db_user}" "${db_password}" "${db_name}"; then
            exit 0
        else
            exit 1
        fi
    else
        if perform_restore "${backup_file}" "${db_host}" "${db_port}" \
                          "${db_user}" "${db_password}" "${db_name}"; then
            exit 0
        else
            exit 1
        fi
    fi
}
