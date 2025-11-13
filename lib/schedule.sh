#!/bin/bash

# ============================================================================
# Module de Planification
# ============================================================================
# Gère la planification automatique des sauvegardes via cron
# ============================================================================

# ============================================================================
# Ajouter une sauvegarde planifiée
# ============================================================================
schedule_add() {
    local name="$1"
    local cron_expr="$2"
    local db_host="$3"
    local db_port="$4"
    local db_user="$5"
    local db_password="$6"
    local db_name="$7"
    local remote_server="$8"
    local enabled="${9:-yes}"

    # Valider le nom de la planification
    if [[ -z "${name}" ]]; then
        log_error "Le nom de la planification est requis"
        return 1
    fi

    # Vérifier si la planification existe déjà
    if schedule_exists "${name}"; then
        log_error "La planification '${name}' existe déjà"
        return 1
    fi

    # Valider l'expression cron
    if [[ -z "${cron_expr}" ]]; then
        log_error "L'expression cron est requise"
        return 1
    fi

    # Créer l'entrée de planification
    local schedule_entry="${name}|${cron_expr}|${db_host}|${db_port}|${db_user}|${db_password}|${db_name}|${remote_server}|${enabled}"
    echo "${schedule_entry}" >> "${SCHEDULES_FILE}"

    log_success "Planification '${name}' ajoutée avec succès"

    # Installer la tâche cron
    if [[ "${enabled}" == "yes" ]]; then
        install_cron_job "${name}"
    fi

    return 0
}

# ============================================================================
# Supprimer une sauvegarde planifiée
# ============================================================================
schedule_remove() {
    local name="$1"

    if [[ -z "${name}" ]]; then
        log_error "Le nom de la planification est requis"
        return 1
    fi

    if ! schedule_exists "${name}"; then
        log_error "Planification '${name}' introuvable"
        return 1
    fi

    # Supprimer du fichier de planifications
    local temp_file=$(mktemp)
    grep -v "^${name}|" "${SCHEDULES_FILE}" > "${temp_file}"
    mv "${temp_file}" "${SCHEDULES_FILE}"

    # Supprimer la tâche cron
    remove_cron_job "${name}"

    log_success "Planification '${name}' supprimée avec succès"
    return 0
}

# ============================================================================
# Lister toutes les sauvegardes planifiées
# ============================================================================
schedule_list() {
    if [[ ! -f "${SCHEDULES_FILE}" ]] || [[ ! -s "${SCHEDULES_FILE}" ]]; then
        echo "Aucune sauvegarde planifiée trouvée"
        return 0
    fi

    printf "%-22s%-18s%-16s%-20s%-16s%-12s\n" "NOM" "PLANIFICATION" "BASE" "HÔTE" "SERVEUR DISTANT" "STATUT"
    printf "%-22s%-18s%-16s%-20s%-16s%-12s\n" "----------------------" "------------------" "----------------" "--------------------" "----------------" "------------"

    while IFS='|' read -r name cron_expr db_host db_port db_user db_password db_name remote_server enabled; do
        status="activé"
        [[ "${enabled}" != "yes" ]] && status="désactivé"
        
        local remote_display="${remote_server:-local}"
        
        printf "%-22s%-18s%-16s%-20s%-16s%-12s\n" \
            "${name}" "${cron_expr}" "${db_name}" "${db_host}:${db_port}" "${remote_display}" "${status}"
    done < "${SCHEDULES_FILE}"

    return 0
}

# ============================================================================
# Modifier une sauvegarde planifiée
# ============================================================================
schedule_modify() {
    local name="$1"
    shift

    if [[ -z "${name}" ]]; then
        log_error "Le nom de la planification est requis"
        return 1
    fi

    if ! schedule_exists "${name}"; then
        log_error "Planification '${name}' introuvable"
        return 1
    fi

    # Obtenir la planification actuelle
    local current_schedule=$(grep "^${name}|" "${SCHEDULES_FILE}")
    IFS='|' read -r _ old_cron old_host old_port old_user old_password old_db old_remote old_enabled <<< "${current_schedule}"

    # Analyser les nouvelles valeurs (conserver les anciennes si non fournies)
    local new_cron="${old_cron}"
    local new_host="${old_host}"
    local new_port="${old_port}"
    local new_user="${old_user}"
    local new_password="${old_password}"
    local new_db="${old_db}"
    local new_remote="${old_remote}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--cron)
                new_cron="$2"
                shift 2
                ;;
            -h|--host)
                new_host="$2"
                shift 2
                ;;
            -P|--port)
                new_port="$2"
                shift 2
                ;;
            -u|--user)
                new_user="$2"
                shift 2
                ;;
            -p|--password)
                new_password="$2"
                shift 2
                ;;
            -d|--database)
                new_db="$2"
                shift 2
                ;;
            --remote|--remote-server)
                new_remote="$2"
                shift 2
                ;;
            --no-remote)
                new_remote=""
                shift
                ;;
            *)
                echo "Erreur : Option inconnue '$1'"
                return 1
                ;;
        esac
    done

    # Mettre à jour la planification
    local temp_file=$(mktemp)
    grep -v "^${name}|" "${SCHEDULES_FILE}" > "${temp_file}"
    echo "${name}|${new_cron}|${new_host}|${new_port}|${new_user}|${new_password}|${new_db}|${new_remote}|${old_enabled}" >> "${temp_file}"
    mv "${temp_file}" "${SCHEDULES_FILE}"

    # Mettre à jour la tâche cron si activée
    if [[ "${old_enabled}" == "yes" ]]; then
        remove_cron_job "${name}"
        install_cron_job "${name}"
    fi

    log_success "Planification '${name}' modifiée avec succès"
    return 0
}

# ============================================================================
# Activer une sauvegarde planifiée
# ============================================================================
schedule_enable() {
    local name="$1"

    if [[ -z "${name}" ]]; then
        log_error "Le nom de la planification est requis"
        return 1
    fi

    if ! schedule_exists "${name}"; then
        log_error "Planification '${name}' introuvable"
        return 1
    fi

    # Mettre à jour le statut activé
    local temp_file=$(mktemp)
    while IFS='|' read -r sname cron_expr db_host db_port db_user db_password db_name remote_server enabled; do
        if [[ "${sname}" == "${name}" ]]; then
            echo "${sname}|${cron_expr}|${db_host}|${db_port}|${db_user}|${db_password}|${db_name}|${remote_server}|yes"
        else
            echo "${sname}|${cron_expr}|${db_host}|${db_port}|${db_user}|${db_password}|${db_name}|${remote_server}|${enabled}"
        fi
    done < "${SCHEDULES_FILE}" > "${temp_file}"
    mv "${temp_file}" "${SCHEDULES_FILE}"

    # Installer la tâche cron
    install_cron_job "${name}"

    log_success "Planification '${name}' activée"
    return 0
}

# ============================================================================
# Désactiver une sauvegarde planifiée
# ============================================================================
schedule_disable() {
    local name="$1"

    if [[ -z "${name}" ]]; then
        log_error "Le nom de la planification est requis"
        return 1
    fi

    if ! schedule_exists "${name}"; then
        log_error "Planification '${name}' introuvable"
        return 1
    fi

    # Mettre à jour le statut activé
    local temp_file=$(mktemp)
    while IFS='|' read -r sname cron_expr db_host db_port db_user db_password db_name remote_server enabled; do
        if [[ "${sname}" == "${name}" ]]; then
            echo "${sname}|${cron_expr}|${db_host}|${db_port}|${db_user}|${db_password}|${db_name}|${remote_server}|no"
        else
            echo "${sname}|${cron_expr}|${db_host}|${db_port}|${db_user}|${db_password}|${db_name}|${remote_server}|${enabled}"
        fi
    done < "${SCHEDULES_FILE}" > "${temp_file}"
    mv "${temp_file}" "${SCHEDULES_FILE}"

    # Supprimer la tâche cron
    remove_cron_job "${name}"

    log_success "Planification '${name}' désactivée"
    return 0
}

# ============================================================================
# Vérifier si une planification existe
# ============================================================================
schedule_exists() {
    local name="$1"
    grep -q "^${name}|" "${SCHEDULES_FILE}" 2>/dev/null
    return $?
}

# ============================================================================
# Installer une tâche cron pour une planification
# ============================================================================
install_cron_job() {
    local name="$1"

    if ! schedule_exists "${name}"; then
        log_error "Planification '${name}' introuvable"
        return 1
    fi

    # Obtenir les détails de la planification
    local schedule_entry
    schedule_entry=$(grep "^${name}|" "${SCHEDULES_FILE}")
    IFS='|' read -r _ cron_expr db_host db_port db_user db_password db_name remote_server enabled <<< "${schedule_entry}"

    if [[ "${enabled}" != "yes" ]]; then
        log_warning "La planification '${name}' est désactivée"
        return 1
    fi

    # Résoudre SCRIPT_DIR et LOG_DIR pour gérer les espaces éventuels dans les chemins
    local quoted_script_dir quoted_log_dir
    quoted_script_dir=$(printf "%q" "${SCRIPT_DIR}")
    quoted_log_dir=$(printf "%q" "${LOG_DIR}")

    # Créer la commande cron avec les dossiers script et log quotés
    local backup_cmd="${quoted_script_dir}/dbbackup backup -h ${db_host} -P ${db_port} -u ${db_user} -p '${db_password}' -d ${db_name}"
    
    # Ajouter le flag --remote si un serveur distant est configuré
    if [[ -n "${remote_server}" ]]; then
        backup_cmd="${backup_cmd} --transfer --remote ${remote_server}"
    fi
    
    local cron_entry="${cron_expr} ${backup_cmd} >> ${quoted_log_dir}/cron-${name}.log 2>&1 # dbbackup-${name}"

    # Obtenir le crontab actuel
    local temp_cron
    temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# dbbackup-${name}" > "${temp_cron}" || true

    # Ajouter la nouvelle entrée cron
    echo "${cron_entry}" >> "${temp_cron}"

    # Installer le nouveau crontab
    if crontab "${temp_cron}" 2>> "${log_file}"; then
        rm -f "${temp_cron}"
        log_success "Tâche cron installée pour la planification '${name}'"
        log_info "Planification : ${cron_expr}"
        if [[ -n "${remote_server}" ]]; then
            log_info "Serveur distant : ${remote_server}"
        fi
        return 0
    else
        rm -f "${temp_cron}"
        log_error "Échec de l'installation de la tâche cron"
        return 1
    fi
}

# ============================================================================
# Supprimer une tâche cron pour une planification
# ============================================================================
remove_cron_job() {
    local name="$1"

    # Obtenir le crontab actuel et supprimer l'entrée
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "# dbbackup-${name}" > "${temp_cron}" || true

    # Installer le crontab mis à jour
    if crontab "${temp_cron}" 2>> "${log_file}"; then
        rm -f "${temp_cron}"
        log_info "Tâche cron supprimée pour la planification '${name}'"
        return 0
    else
        rm -f "${temp_cron}"
        log_error "Échec de la suppression de la tâche cron"
        return 1
    fi
}

# ============================================================================
# Afficher les prochaines exécutions pour toutes les planifications
# ============================================================================
schedule_next_run() {
    echo "Prochaines Exécutions Planifiées :"

    if [[ ! -f "${SCHEDULES_FILE}" ]] || [[ ! -s "${SCHEDULES_FILE}" ]]; then
        echo "Aucune sauvegarde planifiée trouvée"
        return 0
    fi

    while IFS='|' read -r name cron_expr _ _ _ _ _ remote_server enabled; do
        if [[ "${enabled}" == "yes" ]]; then
            echo "Planification : ${name}"
            echo "  Cron : ${cron_expr}"
            if [[ -n "${remote_server}" ]]; then
                echo "  Serveur distant : ${remote_server}"
            else
                echo "  Mode : local"
            fi
            # Note : Calculer le temps d'exécution exact à partir de l'expression cron est complexe
            # Nécessiterait un outil externe ou une analyse complexe
            echo ""
        fi
    done < "${SCHEDULES_FILE}"
}


schedule_show_help() {
    cat << EOF
Gestion de la planification des sauvegardes :

    dbbackup schedule [action] [options]
        Gérer les sauvegardes planifiées via cron.

Actions :
    add        Ajouter une nouvelle planification de sauvegarde.
    list       Lister toutes les sauvegardes planifiées.
    remove     Supprimer une planification existante.
    modify     Modifier une planification existante.
    enable     Activer une sauvegarde planifiée.
    disable    Désactiver une sauvegarde planifiée.
    next       Afficher la date de la prochaine exécution pour chaque sauvegarde.

Options de 'add' et 'modify' :
    -n, --name <nom>              Nom de la planification (obligatoire)
    -c, --cron <expr>             Expression cron (obligatoire)
    -h, --host <hôte>             Hôte de la base de données (défaut : localhost)
    -P, --port <port>             Port de la base de données (défaut : 3306)
    -u, --user <utilisateur>      Utilisateur de la base de données (obligatoire)
    -p, --password <mot_de_passe> Mot de passe de la base de données (obligatoire)
    -d, --database <nom>          Nom de la base de données (obligatoire)
    --remote <nom>                Nom du serveur distant pour transfert automatique
    --no-remote                   Désactiver le transfert distant (pour modify)

Exemples :
    # Ajouter une sauvegarde planifiée locale tous les jours à 2h
    dbbackup schedule add -n "daily" -c "0 2 * * *" -u root -p secret -d mydb

    # Ajouter une sauvegarde planifiée distante
    dbbackup schedule add -n "daily-remote" -c "0 2 * * *" -u root -p secret -d mydb --remote prod-server

    # Lister les sauvegardes planifiées
    dbbackup schedule list

    # Modifier une planification pour ajouter un serveur distant
    dbbackup schedule modify daily --remote prod-server

    # Modifier une planification pour supprimer le transfert distant
    dbbackup schedule modify daily-remote --no-remote

    # Supprimer une planification
    dbbackup schedule remove daily

    # Activer/désactiver une planification
    dbbackup schedule enable daily
    dbbackup schedule disable daily

    # Afficher la prochaine exécution de chaque sauvegarde
    dbbackup schedule next

EOF
}

# ============================================================================
# Commande : gestion de planification
# ============================================================================
cmd_schedule() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        add)
            cmd_schedule_add "$@"
            ;;
        remove|rm|delete)
            if [[ $# -lt 1 ]]; then
                echo "Erreur : Nom de planification requis"
                echo "Usage : dbbackup schedule remove <nom>"
                exit 1
            fi
            schedule_remove "$1"
            ;;
        list|ls)
            schedule_list
            ;;
        modify|edit|update)
            if [[ $# -lt 1 ]]; then
                echo "Erreur : Nom de planification requis"
                echo "Usage : dbbackup schedule modify <nom> [options]"
                exit 1
            fi
            schedule_modify "$@"
            ;;
        enable)
            if [[ $# -lt 1 ]]; then
                echo "Erreur : Nom de planification requis"
                echo "Usage : dbbackup schedule enable <nom>"
                exit 1
            fi
            schedule_enable "$1"
            ;;
        disable)
            if [[ $# -lt 1 ]]; then
                echo "Erreur : Nom de planification requis"
                echo "Usage : dbbackup schedule disable <nom>"
                exit 1
            fi
            schedule_disable "$1"
            ;;
        next)
            schedule_next_run
            ;;
        *)
            echo "Commande inconnue : $action"
            schedule_show_help
            exit 1
            ;;
    esac
}

# ============================================================================
# Commande : ajouter une planification
# ============================================================================
cmd_schedule_add() {
    local name=""
    local cron_expr=""
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-3306}"
    local db_user=""
    local db_password=""
    local db_name=""
    local remote_server=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--name)
                name="$2"
                shift 2
                ;;
            -c|--cron)
                cron_expr="$2"
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
            --remote|--remote-server)
                remote_server="$2"
                shift 2
                ;;
            *)
                echo "Erreur : Option inconnue '$1'"
                schedule_show_help
                exit 1
                ;;
        esac
    done

    # Valider les paramètres requis
    if [[ -z "${name}" ]]; then
        echo "Erreur : Le nom de la planification est requis (-n ou --name)"
        exit 1
    fi

    if [[ -z "${cron_expr}" ]]; then
        echo "Erreur : L'expression cron est requise (-c ou --cron)"
        exit 1
    fi

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

    # Vérifier que le serveur distant existe si spécifié
    if [[ -n "${remote_server}" ]]; then
        if ! remote_exists "${remote_server}"; then
            echo "Erreur : Le serveur distant '${remote_server}' n'existe pas."
            echo "Utilisez 'dbbackup remote list' pour voir les serveurs disponibles."
            exit 1
        fi
    fi

    schedule_add "${name}" "${cron_expr}" "${db_host}" "${db_port}" \
                 "${db_user}" "${db_password}" "${db_name}" "${remote_server}" "yes"
}

# ============================================================================
# Commande : lister les planifications
# ============================================================================
cmd_schedule_list() {
    schedule_list
}