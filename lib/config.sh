#!/bin/bash

# ============================================================================
# Module de Gestion de Configuration
# ============================================================================
# Gère le chargement, la validation et la gestion de la configuration
# ============================================================================

CONFIG_FILE="${CONFIG_DIR}/dbbackup.conf"
ENCRYPTION_KEY_FILE="${CONFIG_DIR}/encryption.key"
TRANSFER_CONFIG_FILE="${CONFIG_DIR}/transfer.conf"
SCHEDULES_FILE="${CONFIG_DIR}/schedules.conf"
REMOTE_SERVERS_DIR="${CONFIG_DIR}/remotes"

# Valeurs de configuration par défaut
DEFAULT_DB_HOST="localhost"
DEFAULT_DB_PORT="3306"
DEFAULT_BACKUP_DIR="${SCRIPT_DIR}/backups"
DEFAULT_LOG_RETENTION_DAYS="30"
DEFAULT_BACKUP_RETENTION_DAYS="7"

# ============================================================================
# Initialiser les fichiers de configuration
# ============================================================================
init_config() {
    # Créer le répertoire de configuration s'il n'existe pas
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${DEFAULT_BACKUP_DIR}"
    mkdir -p "${REMOTE_SERVERS_DIR}"

    # Créer la configuration par défaut si elle n'existe pas
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        create_default_config
    fi

    # Créer la clé de chiffrement si elle n'existe pas
    if [[ ! -f "${ENCRYPTION_KEY_FILE}" ]]; then
        generate_encryption_key
    fi

    # Créer la configuration de transfert si elle n'existe pas
    if [[ ! -f "${TRANSFER_CONFIG_FILE}" ]]; then
        create_transfer_config
    fi
    migrate_legacy_transfer_config

    # Créer le fichier de planifications s'il n'existe pas
    if [[ ! -f "${SCHEDULES_FILE}" ]]; then
        touch "${SCHEDULES_FILE}"
    fi

    # Mettre à jour la configuration existante si nécessaire
    migrate_transfer_default

    # Charger la configuration
    load_config
}

# ============================================================================
# Créer le fichier de configuration par défaut
# ============================================================================
create_default_config() {
    cat > "${CONFIG_FILE}" << EOF
# Fichier de Configuration DBBackup CLI
# ============================================================================

# Paramètres de base de données par défaut
DB_HOST="${DEFAULT_DB_HOST}"
DB_PORT="${DEFAULT_DB_PORT}"

# Paramètres de sauvegarde
BACKUP_DIR="${DEFAULT_BACKUP_DIR}"
BACKUP_RETENTION_DAYS="${DEFAULT_BACKUP_RETENTION_DAYS}"

# Paramètres de journalisation
LOG_RETENTION_DAYS="${DEFAULT_LOG_RETENTION_DAYS}"

# Journaux
ENABLE_LOGGING="no"

# Somme de contrôles
KEEP_CHECKSUMS_AFTER_BACKUP="no"

# Notifications
NOTIFICATION_EMAIL=""
NOTIFICATION_ON_SUCCESS="no"
NOTIFICATION_ON_FAILURE="no"
EOF

    log_info "Configuration par défaut créée : ${CONFIG_FILE}"
}

# ============================================================================
# Générer une clé de chiffrement
# ============================================================================
generate_encryption_key() {
    # Générer une clé aléatoire de 256 bits
    openssl rand -base64 32 > "${ENCRYPTION_KEY_FILE}"
    chmod 600 "${ENCRYPTION_KEY_FILE}"
    log_info "Clé de chiffrement générée : ${ENCRYPTION_KEY_FILE}"
}

# ============================================================================
# Mettre à jour la configuration existante pour désactiver le transfert par défaut
# ============================================================================
migrate_transfer_default() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return
    fi

    if grep -q '^TRANSFER_DEFAULT_VERSION=' "${CONFIG_FILE}" 2>/dev/null; then
        return
    fi

    local had_remote_default="no"
    if grep -q '^TRANSFER="yes"' "${CONFIG_FILE}" 2>/dev/null; then
        had_remote_default="yes"
    fi

    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/.dbbackup_conf.XXXXXX")

    awk -v enforce="${had_remote_default}" '
        /^TRANSFER="/ {
            if (enforce == "yes" && $0 ~ /^TRANSFER="yes"/) {
                sub(/"yes"/, "\"no\"")
            }
        }
        { print }
        END {
            print "TRANSFER_DEFAULT_VERSION=\"2\""
        }
    ' "${CONFIG_FILE}" > "${tmp_file}"

    mv "${tmp_file}" "${CONFIG_FILE}"

    if [[ "${had_remote_default}" == "yes" ]]; then
        log_info "Le transfert distant n'est plus activé par défaut."
    fi
}

# ============================================================================
# Créer le modèle de configuration de transfert
# ============================================================================
create_transfer_config() {
    echo ""
    cat > "${TRANSFER_CONFIG_FILE}" << EOF
# Configuration des serveurs distants DBBackup CLI
# ============================================================================
# Utilisez la commande 'dbbackup remote' pour gérer les serveurs distants.

# Serveur distant utilisé par défaut lors d'un transfert
DEFAULT_REMOTE_SERVER=""
EOF

    log_info "Modèle de configuration de transfert créé : ${TRANSFER_CONFIG_FILE}"
}

# ============================================================================
# Migrer l'ancien fichier de transfert (mono-serveur) vers le nouveau format
# ============================================================================
migrate_legacy_transfer_config() {
    if [[ ! -f "${TRANSFER_CONFIG_FILE}" ]]; then
        return
    fi

    # Si des serveurs existent déjà, rien à migrer
    if [[ -n "$(find "${REMOTE_SERVERS_DIR}" -maxdepth 1 -type f -name '*.conf' -print -quit 2>/dev/null)" ]]; then
        return
    fi

    if ! grep -q '^REMOTE_HOST=' "${TRANSFER_CONFIG_FILE}" 2>/dev/null; then
        return
    fi

    local legacy_file="${REMOTE_SERVERS_DIR}/default.conf"
    cp "${TRANSFER_CONFIG_FILE}" "${legacy_file}"

    if ! grep -q '^REMOTE_NAME=' "${legacy_file}" 2>/dev/null; then
        cat >> "${legacy_file}" <<EOF
REMOTE_NAME="default"
EOF
    fi

    cat > "${TRANSFER_CONFIG_FILE}" << EOF
# Configuration des serveurs distants DBBackup CLI
# ============================================================================
# Fichier migré automatiquement pour le support multi-serveurs.
DEFAULT_REMOTE_SERVER="default"
EOF

    log_info "Configuration de transfert migrée vers ${legacy_file}"
}

# ============================================================================
# Charger la configuration
# ============================================================================
load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        source "${CONFIG_FILE}"
    fi

    if [[ -f "${TRANSFER_CONFIG_FILE}" ]]; then
        source "${TRANSFER_CONFIG_FILE}"
    fi

    : "${DEFAULT_REMOTE_SERVER:=}"
}

# ============================================================================
# Obtenir une valeur de configuration
# ============================================================================
get_config() {
    local key="$1"
    grep "^${key}=" "${CONFIG_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '"'
}

# ============================================================================
# Afficher la configuration actuelle
# ============================================================================
show_config() {
    echo "Configuration Actuelle :"
    echo ""
    cat "${CONFIG_FILE}"
    echo ""
    echo "Configuration de Transfert :"
    echo ""
    if [[ -f "${TRANSFER_CONFIG_FILE}" ]]; then
        cat "${TRANSFER_CONFIG_FILE}"
    else
        echo "(Aucune configuration de transfert trouvée)"
    fi
    echo ""
    echo "Serveurs distants disponibles :"
    echo ""
    if [[ -d "${REMOTE_SERVERS_DIR}" ]]; then
        shopt -s nullglob
        local remote_files=("${REMOTE_SERVERS_DIR}"/*.conf)
        shopt -u nullglob
        if [[ ${#remote_files[@]} -eq 0 ]]; then
            echo "Aucun serveur configuré."
        else
            for remote_file in "${remote_files[@]}"; do
                local remote_name remote_host
                remote_name=$(grep '^REMOTE_NAME=' "${remote_file}" | cut -d'=' -f2- | tr -d '"')
                if [[ -z "${remote_name}" ]]; then
                    remote_name=$(basename "${remote_file}" .conf)
                fi
                remote_host=$(grep '^REMOTE_HOST=' "${remote_file}" | cut -d'=' -f2- | tr -d '"')
                printf " - %s (%s)\n" "${remote_name}" "${remote_host:-?}"
            done
        fi
    else
        echo "Aucun serveur configuré."
    fi
    echo ""
    echo "Clé de Chiffrement : ${ENCRYPTION_KEY_FILE}"
    echo "Fichier de Planifications : ${SCHEDULES_FILE}"
    echo ""
}

# ============================================================================
# Fonctions de journalisation
# ============================================================================
log_file="${LOG_DIR}/dbbackup-$(date +%Y%m%d).log"

log_message() {
    local level="$1"
    shift
    local message="$@"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local enable_logging="${ENABLE_LOGGING:-no}"
    if [[ "${enable_logging}" == "yes" ]]; then
        echo "[${timestamp}] [${level}] ${message}" | tee -a "${log_file}"
    else
        echo "[${timestamp}] [${level}] ${message}" >> "${log_file}"
    fi
}

log_info() {
    log_message "INFO" "$@"
}

log_error() {
    log_message "ERREUR" "$@" >&2
}

log_success() {
    log_message "SUCCES" "$@"
}

log_warning() {
    log_message "AVERTISSEMENT" "$@"
}

config_show_help() {
    cat << EOF
Gestion de la configuration :
    dbbackup config show
        Afficher la configuration actuelle du système (dossiers, clé de chiffrement, serveurs distants, planifications...).

Exemple :
    dbbackup config show
EOF
}

cmd_config() {
    if [[ $# -eq 0 ]]; then
        config_show_help
        exit 0
    fi

    local subcommand="$1"
    shift

    case "${subcommand}" in
        show)
            show_config
            ;;
        *)
            echo "Commande inconnue : ${subcommand}"
            config_show_help
            exit 1
            ;;
    esac

}