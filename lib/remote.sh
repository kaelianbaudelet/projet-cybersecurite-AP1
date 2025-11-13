#!/bin/bash

# ============================================================================
# Module de Gestion des Serveurs Distants
# ============================================================================
# Permet la création, la suppression, la liste et le chargement des serveurs distants.
# ============================================================================

# ============================================================================
# Utilitaires internes
# ============================================================================
remote_validate_name() {
    local name="$1"
    [[ "${name}" =~ ^[A-Za-z0-9_-]+$ ]]
}

remote_config_path() {
    local name="$1"
    echo "${REMOTE_SERVERS_DIR}/${name}.conf"
}

remote_exists() {
    local name="$1"
    [[ -f "$(remote_config_path "${name}")" ]]
}

# ============================================================================
# Charger la configuration d'un serveur distant
# ============================================================================
use_remote_server() {
    local name="$1"

    if [[ -z "${name:-}" ]]; then
        log_error "Aucun serveur distant spécifié pour le transfert."
        return 1
    fi

    if ! remote_validate_name "${name}"; then
        log_error "Nom de serveur distant invalide : ${name}"
        return 1
    fi

    local config_file
    config_file=$(remote_config_path "${name}")

    if [[ ! -f "${config_file}" ]]; then
        log_error "Serveur distant '${name}' introuvable. Utilisez 'dbbackup remote list' pour vérifier."
        return 1
    fi

    # Réinitialiser les variables pour éviter les résidus d'un précédent chargement
    unset REMOTE_NAME REMOTE_HOST REMOTE_PORT REMOTE_USER REMOTE_PATH
    unset REMOTE_AUTH_METHOD REMOTE_SSH_KEY REMOTE_PASSWORD
    unset REMOTE_VERIFY_INTEGRITY REMOTE_DELETE_AFTER_TRANSFER

    # shellcheck source=/dev/null
    source "${config_file}"

    ACTIVE_REMOTE_NAME="${REMOTE_NAME:-${name}}"
    REMOTE_HOST="${REMOTE_HOST:-}"
    REMOTE_PORT="${REMOTE_PORT:-22}"
    REMOTE_USER="${REMOTE_USER:-}"
    REMOTE_PATH="${REMOTE_PATH:-/backups}"
    REMOTE_AUTH_METHOD="${REMOTE_AUTH_METHOD:-key}"
    REMOTE_SSH_KEY="${REMOTE_SSH_KEY:-${HOME}/.ssh/id_rsa}"
    REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
    REMOTE_VERIFY_INTEGRITY="${REMOTE_VERIFY_INTEGRITY:-yes}"
    REMOTE_DELETE_AFTER_TRANSFER="${REMOTE_DELETE_AFTER_TRANSFER:-no}"

    if [[ -z "${REMOTE_HOST}" ]]; then
        log_error "Le serveur distant '${name}' n'a pas d'hôte configuré."
        return 1
    fi

    if [[ -z "${REMOTE_USER}" ]]; then
        log_error "Le serveur distant '${name}' n'a pas d'utilisateur configuré."
        return 1
    fi

    if [[ "${REMOTE_AUTH_METHOD}" == "password" && -z "${REMOTE_PASSWORD}" ]]; then
        log_error "Le mot de passe est requis pour le serveur distant '${name}'."
        return 1
    fi

    if [[ "${REMOTE_AUTH_METHOD}" == "key" && -z "${REMOTE_SSH_KEY}" ]]; then
        log_error "La clé SSH est requise pour le serveur distant '${name}'."
        return 1
    fi

    return 0
}

# ============================================================================
# Helpers pour la sortie utilisateur
# ============================================================================
remote_list_servers() {
    if [[ ! -d "${REMOTE_SERVERS_DIR}" ]]; then
        echo "Aucun serveur configuré."
        return 0
    fi

    shopt -s nullglob
    local remote_files=("${REMOTE_SERVERS_DIR}"/*.conf)
    shopt -u nullglob

    if [[ ${#remote_files[@]} -eq 0 ]]; then
        echo "Aucun serveur configuré."
        return 0
    fi

    local default_server="${DEFAULT_REMOTE_SERVER:-}"
    for remote_file in "${remote_files[@]}"; do
        local remote_name remote_host marker
        remote_name=$(grep '^REMOTE_NAME=' "${remote_file}" | cut -d'=' -f2- | tr -d '"')
        if [[ -z "${remote_name}" ]]; then
            remote_name=$(basename "${remote_file}" .conf)
        fi
        remote_host=$(grep '^REMOTE_HOST=' "${remote_file}" | cut -d'=' -f2- | tr -d '"')
        marker=""
        if [[ -n "${default_server}" && "${remote_name}" == "${default_server}" ]]; then
            marker=" *"
        fi
        printf "%s%s - %s\n" "${remote_name}" "${marker}" "${remote_host:-?}"
    done
}

remote_write_config() {
    local destination="$1"
    local name="$2"
    local host="$3"
    local port="$4"
    local user="$5"
    local path="$6"
    local auth_method="$7"
    local ssh_key="$8"
    local password="$9"
    local verify="${10}"
    local delete_after="${11}"

    {
        echo "# Configuration du serveur distant '${name}' générée par DBBackup CLI"
        printf 'REMOTE_NAME=%q\n' "${name}"
        printf 'REMOTE_HOST=%q\n' "${host}"
        printf 'REMOTE_PORT=%q\n' "${port}"
        printf 'REMOTE_USER=%q\n' "${user}"
        printf 'REMOTE_PATH=%q\n' "${path}"
        printf 'REMOTE_AUTH_METHOD=%q\n' "${auth_method}"
        printf 'REMOTE_SSH_KEY=%q\n' "${ssh_key}"
        printf 'REMOTE_PASSWORD=%q\n' "${password}"
        printf 'REMOTE_VERIFY_INTEGRITY=%q\n' "${verify}"
        printf 'REMOTE_DELETE_AFTER_TRANSFER=%q\n' "${delete_after}"
    } > "${destination}"
}

remote_update_default_server() {
    local new_default="$1"
    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/.transfer.XXXXXX")

    if [[ -f "${TRANSFER_CONFIG_FILE}" ]]; then
        awk -v val="${new_default}" '
            BEGIN { replaced = 0 }
            /^DEFAULT_REMOTE_SERVER=/ {
                print "DEFAULT_REMOTE_SERVER=\"" val "\""
                replaced = 1
                next
            }
            { print }
            END {
                if (replaced == 0) {
                    print "DEFAULT_REMOTE_SERVER=\"" val "\""
                }
            }
        ' "${TRANSFER_CONFIG_FILE}" > "${tmp_file}"
    else
        printf 'DEFAULT_REMOTE_SERVER="%s"\n' "${new_default}" > "${tmp_file}"
    fi

    mv "${tmp_file}" "${TRANSFER_CONFIG_FILE}"
    DEFAULT_REMOTE_SERVER="${new_default}"
}

# ============================================================================
# Commandes CLI
# ============================================================================
cmd_remote() {
    if [[ $# -eq 0 ]]; then
        remote_show_help
        exit 0
    fi

    local subcommand="$1"
    shift

    case "${subcommand}" in
        list)
            remote_list_servers
            ;;
        add)
            remote_cmd_add "$@"
            ;;
        remove|rm|delete)
            remote_cmd_remove "$@"
            ;;
        show)
            remote_cmd_show "$@"
            ;;
        set-default)
            remote_cmd_set_default "$@"
            ;;
        test)
            remote_cmd_test "$@"
            ;;
        help|-h|--help)
            remote_show_help
            ;;
        *)
            echo "Commande inconnue : ${subcommand}"
            remote_show_help
            exit 1
            ;;
    esac
}

remote_show_help() {
    cat << EOF
Gestion des serveurs distants :

    dbbackup remote [options]
        Gérer les serveurs distants utilisés pour les sauvegardes et restaurations.

        Options :
            list                        Lister les serveurs distants configurés (le serveur par défaut est marqué d'une *).
            add <nom> --host <hôte> --user <utilisateur> [options]
            Ajouter un nouveau serveur distant.
                --port <port>              Port SSH (défaut : 22)
                --path <chemin>            Chemin distant pour les sauvegardes (défaut : /backups)
                --auth <key|password>      Méthode d'authentification (défaut : key)
                --ssh-key <chemin_clé>     Chemin clé SSH (pour auth=key, défaut : ~/.ssh/id_rsa)
                --password <mot_de_passe>  Mot de passe (pour auth=password)
                --verify <yes|no>          Vérifier l'intégrité après transfert (défaut : yes)
                --delete-after <yes|no>    Supprimer après transfert (défaut : no)
                --set-default              Définir ce serveur comme défaut immédiatement.
            show <nom>                 Afficher la configuration d'un serveur distant.
            remove <nom>               Supprimer un serveur distant.
            set-default <nom>          Définir le serveur distant par défaut.
            test <nom>                 Tester la connexion SSH/SFTP au serveur distant spécifié.

Exemples :
    # Lister les serveurs distants disponibles
    dbbackup remote list

    # Ajouter un serveur distant
    dbbackup remote add prod-server --host backup.example.com --user backupuser --auth key --ssh-key ~/.ssh/id_rsa --path /srv/backups --set-default

    # Afficher la configuration d'un serveur distant
    dbbackup remote show prod-server

    # Supprimer un serveur distant
    dbbackup remote remove prod-server

    # Définir un serveur distant par défaut
    dbbackup remote set-default prod-server

    # Tester la connexion à un serveur distant
    dbbackup remote test prod-server

EOF
}

remote_cmd_add() {
    if [[ $# -lt 1 ]]; then
        echo "Usage : dbbackup remote add <nom> --host <hôte> --user <utilisateur> [options]"
        exit 1
    fi

    local name="$1"
    shift

    if ! remote_validate_name "${name}"; then
        echo "Nom de serveur invalide : ${name}. Utilisez uniquement lettres, chiffres, - ou _."
        exit 1
    fi

    if remote_exists "${name}"; then
        echo "Le serveur distant '${name}' existe déjà."
        exit 1
    fi

    local host="" port="22" user="" path="/backups"
    local auth_method="key" ssh_key="${HOME}/.ssh/id_rsa" password=""
    local verify="yes" delete_after="no" set_default="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                host="$2"; shift 2 ;;
            --port)
                port="$2"; shift 2 ;;
            --user)
                user="$2"; shift 2 ;;
            --path)
                path="$2"; shift 2 ;;
            --auth)
                auth_method="$2"; shift 2 ;;
            --ssh-key)
                ssh_key="$2"; shift 2 ;;
            --password)
                password="$2"; shift 2 ;;
            --verify)
                verify="$2"; shift 2 ;;
            --delete-after)
                delete_after="$2"; shift 2 ;;
            --set-default)
                set_default="yes"; shift ;;
            *)
                echo "Option inconnue : $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "${host}" || -z "${user}" ]]; then
        echo "Les options --host et --user sont obligatoires."
        exit 1
    fi

    if [[ "${auth_method}" != "key" && "${auth_method}" != "password" ]]; then
        echo "La méthode d'authentification doit être 'key' ou 'password'."
        exit 1
    fi

    if [[ "${auth_method}" == "password" && -z "${password}" ]]; then
        echo "Veuillez renseigner --password pour l'authentification par mot de passe."
        exit 1
    fi

    if [[ "${auth_method}" == "key" && -z "${ssh_key}" ]]; then
        echo "Veuillez renseigner --ssh-key pour l'authentification par clé."
        exit 1
    fi

    local config_file
    config_file=$(remote_config_path "${name}")

    remote_write_config "${config_file}" "${name}" "${host}" "${port}" "${user}" \
        "${path}" "${auth_method}" "${ssh_key}" "${password}" "${verify}" "${delete_after}"

    echo "Serveur distant '${name}' ajouté."

    if [[ "${set_default}" == "yes" ]]; then
        remote_update_default_server "${name}"
        echo "Le serveur '${name}' est désormais le serveur par défaut."
    fi
}

remote_cmd_remove() {
    if [[ $# -lt 1 ]]; then
        echo "Usage : dbbackup remote remove <nom>"
        exit 1
    fi

    local name="$1"

    if ! remote_exists "${name}"; then
        echo "Serveur distant '${name}' introuvable."
        exit 1
    fi

    local current_default="${DEFAULT_REMOTE_SERVER:-}"
    rm -f "$(remote_config_path "${name}")"
    echo "Serveur distant '${name}' supprimé."

    if [[ "${current_default}" == "${name}" ]]; then
        remote_update_default_server ""
        echo "Le serveur par défaut a été réinitialisé (il ne pointait plus vers un serveur existant)."
    fi
}

remote_cmd_show() {
    if [[ $# -lt 1 ]]; then
        echo "Usage : dbbackup remote show <nom>"
        exit 1
    fi

    local name="$1"

    if ! remote_exists "${name}"; then
        echo "Serveur distant '${name}' introuvable."
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$(remote_config_path "${name}")"

    echo "Nom          : ${REMOTE_NAME:-$name}"
    echo "Hôte         : ${REMOTE_HOST}"
    echo "Port         : ${REMOTE_PORT}"
    echo "Utilisateur  : ${REMOTE_USER}"
    echo "Chemin       : ${REMOTE_PATH}"
    echo "Authentif.   : ${REMOTE_AUTH_METHOD}"
    echo "Clé SSH      : ${REMOTE_SSH_KEY}"
    if [[ -n "${REMOTE_PASSWORD}" ]]; then
        echo "Mot de passe : (défini)"
    else
        echo "Mot de passe : (non défini)"
    fi
    echo "Vérification : ${REMOTE_VERIFY_INTEGRITY}"
    echo "Suppression  : ${REMOTE_DELETE_AFTER_TRANSFER}"
}

remote_cmd_set_default() {
    if [[ $# -lt 1 ]]; then
        echo "Usage : dbbackup remote set-default <nom>"
        exit 1
    fi

    local name="$1"

    if ! remote_exists "${name}"; then
        echo "Serveur distant '${name}' introuvable."
        exit 1
    fi

    remote_update_default_server "${name}"
    echo "Serveur distant par défaut défini sur '${name}'."
}

remote_cmd_test() {
    if [[ $# -lt 1 ]]; then
        echo "Usage : dbbackup remote test <nom>"
        exit 1
    fi

    local name="$1"

    if ! use_remote_server "${name}"; then
        exit 1
    fi

    if test_remote_connection; then
        echo "Test de connexion réussi pour '${name}'."
    else
        echo "Échec du test de connexion pour '${name}'."
        exit 1
    fi
}
