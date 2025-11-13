#!/bin/bash
# transfer.sh

# ============================================================================
# Module de Transfert
# ============================================================================
# Gère le transfert sécurisé de fichiers vers un serveur distant via SFTP/SCP
# ============================================================================

# ============================================================================
# Transférer un fichier vers le serveur distant
# ============================================================================
transfer_file() {
    local file_path="$1"
    local checksum_file="${2:-}"
    local remote_display="${ACTIVE_REMOTE_NAME:-}"
    if [[ ! -f "${file_path}" ]]; then
        log_error "Fichier introuvable : ${file_path}"
        return 1
    fi
    if [[ -z "${remote_display}" ]]; then
        log_error "Aucun serveur distant chargé."
        return 1
    fi
    if [[ -z "${REMOTE_HOST}" ]]; then
        log_warning "Hôte distant non configuré pour '${remote_display}'."
        return 1
    fi
    log_info "Transfert vers ${remote_display} (${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH})"
    if ! ensure_remote_directory; then
        log_error "Échec création répertoire distant"
        return 1
    fi
    if [[ "${REMOTE_AUTH_METHOD}" == "key" ]]; then
        if ! transfer_with_key "${file_path}" "${checksum_file}"; then
            return 1
        fi
    else
        if ! transfer_with_password "${file_path}" "${checksum_file}"; then
            return 1
        fi
    fi
    if [[ "${REMOTE_VERIFY_INTEGRITY}" == "yes" && -n "${checksum_file}" ]]; then
        log_info "Vérification intégrité distante..."
        if ! verify_remote_integrity "${file_path}" "${checksum_file}"; then
            log_error "Échec vérification intégrité distante"
            return 1
        fi
        log_success "Vérification intégrité distante réussie"
    fi
    log_success "Transfert terminé"
    return 0
}

# ============================================================================
# Transférer un fichier avec authentification par clé SSH
# ============================================================================
transfer_with_key() {
    local file_path="$1"
    local checksum_file="$2"

    if [[ ! -f "${REMOTE_SSH_KEY}" ]]; then
        log_error "Clé SSH introuvable : ${REMOTE_SSH_KEY}"
        return 1
    fi

    local remote_file="${REMOTE_PATH}/$(basename "${file_path}")"
    local remote_checksum="${REMOTE_PATH}/$(basename "${checksum_file}")"

    # Transférer le fichier de sauvegarde
    log_info "Transfert du fichier de sauvegarde..."
    if ! scp -P "${REMOTE_PORT}" -i "${REMOTE_SSH_KEY}" \
             -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR \
             "${file_path}" \
             "${REMOTE_USER}@${REMOTE_HOST}:${remote_file}" 2>> "${log_file}"; then
        log_error "Échec du transfert du fichier de sauvegarde"
        return 1
    fi

    # Transférer le fichier de somme de contrôle
    if [[ -f "${checksum_file}" ]]; then
        log_info "Transfert du fichier de somme de contrôle..."
        if ! scp -P "${REMOTE_PORT}" -i "${REMOTE_SSH_KEY}" \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR \
                 "${checksum_file}" \
                 "${REMOTE_USER}@${REMOTE_HOST}:${remote_checksum}" 2>> "${log_file}"; then
            log_warning "Échec du transfert du fichier de somme de contrôle"
        fi
    fi

    return 0
}

# ============================================================================
# Transférer un fichier avec authentification par mot de passe
# ============================================================================
transfer_with_password() {
    local file_path="$1"
    local checksum_file="$2"

    # Vérifier si sshpass est disponible
    if ! command -v sshpass &> /dev/null; then
        log_error "Commande sshpass introuvable. Installez sshpass ou utilisez l'authentification par clé."
        return 1
    fi

    if [[ -z "${REMOTE_PASSWORD}" ]]; then
        log_error "Mot de passe distant non configuré"
        return 1
    fi

    local remote_file="${REMOTE_PATH}/$(basename "${file_path}")"
    local remote_checksum="${REMOTE_PATH}/$(basename "${checksum_file}")"

    # Transférer le fichier de sauvegarde
    log_info "Transfert du fichier de sauvegarde..."
    if ! sshpass -p "${REMOTE_PASSWORD}" scp -P "${REMOTE_PORT}" \
             -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR \
             "${file_path}" \
             "${REMOTE_USER}@${REMOTE_HOST}:${remote_file}" 2>> "${log_file}"; then
        log_error "Échec du transfert du fichier de sauvegarde"
        return 1
    fi

    # Transférer le fichier de somme de contrôle
    if [[ -f "${checksum_file}" ]]; then
        log_info "Transfert du fichier de somme de contrôle..."
        if ! sshpass -p "${REMOTE_PASSWORD}" scp -P "${REMOTE_PORT}" \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR \
                 "${checksum_file}" \
                 "${REMOTE_USER}@${REMOTE_HOST}:${remote_checksum}" 2>> "${log_file}"; then
            log_warning "Échec du transfert du fichier de somme de contrôle"
        fi
    fi

    return 0
}

# ============================================================================
# S'assurer que le répertoire distant existe
# ============================================================================
ensure_remote_directory() {
    local ssh_cmd

    if [[ "${REMOTE_AUTH_METHOD}" == "key" ]]; then
        ssh_cmd="ssh -p ${REMOTE_PORT} -i ${REMOTE_SSH_KEY} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR"
    else
        if ! command -v sshpass &> /dev/null; then
            log_error "sshpass introuvable"
            return 1
        fi
        ssh_cmd="sshpass -p ${REMOTE_PASSWORD} ssh -p ${REMOTE_PORT} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR"
    fi

    # Créer le répertoire sur le serveur distant
    ${ssh_cmd} "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p ${REMOTE_PATH}" 2>> "${log_file}"

    return $?
}

# ============================================================================
# Vérifier l'intégrité du fichier sur le serveur distant
# ============================================================================
verify_remote_integrity() {
    local file_path="$1"
    local checksum_file="$2"

    if [[ ! -f "${checksum_file}" ]]; then
        log_warning "Fichier de somme de contrôle local introuvable"
        return 1
    fi

    local remote_file="${REMOTE_PATH}/$(basename "${file_path}")"
    local local_checksum=$(cat "${checksum_file}" | awk '{print $1}')

    local ssh_cmd
    if [[ "${REMOTE_AUTH_METHOD}" == "key" ]]; then
        ssh_cmd="ssh -p ${REMOTE_PORT} -i ${REMOTE_SSH_KEY} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR"
    else
        ssh_cmd="sshpass -p ${REMOTE_PASSWORD} ssh -p ${REMOTE_PORT} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o LogLevel=ERROR"
    fi

    # Obtenir la somme de contrôle depuis le serveur distant
    local remote_checksum
    if command -v shasum &> /dev/null; then
        remote_checksum=$(${ssh_cmd} "${REMOTE_USER}@${REMOTE_HOST}" \
            "shasum -a 256 ${remote_file}" 2>> "${log_file}" | awk '{print $1}')
    else
        remote_checksum=$(${ssh_cmd} "${REMOTE_USER}@${REMOTE_HOST}" \
            "sha256sum ${remote_file}" 2>> "${log_file}" | awk '{print $1}')
    fi

    if [[ -z "${remote_checksum}" ]]; then
        log_error "Échec de l'obtention de la somme de contrôle distante"
        return 1
    fi

    if [[ "${local_checksum}" == "${remote_checksum}" ]]; then
        log_success "Intégrité distante vérifiée"
        return 0
    else
        log_error "Échec de la vérification de l'intégrité distante !"
        log_error "Locale :  ${local_checksum}"
        log_error "Distante : ${remote_checksum}"
        return 1
    fi
}

# ============================================================================
# Télécharger un fichier depuis le serveur distant
# ============================================================================
download_file() {
    local remote_file="$1"
    local local_path="$2"

    log_info "Téléchargement depuis le serveur distant..."

    if [[ "${REMOTE_AUTH_METHOD}" == "key" ]]; then
        scp -P "${REMOTE_PORT}" -i "${REMOTE_SSH_KEY}" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/${remote_file}" \
            "${local_path}" 2>> "${log_file}"
    else
        sshpass -p "${REMOTE_PASSWORD}" scp -P "${REMOTE_PORT}" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/${remote_file}" \
            "${local_path}" 2>> "${log_file}"
    fi

    if [[ $? -ne 0 ]]; then
        log_error "Échec du téléchargement du fichier depuis le serveur distant"
        return 1
    fi

    log_success "Fichier téléchargé avec succès"
    return 0
}

# ============================================================================
# Lister les fichiers de sauvegarde distants
# ============================================================================

list_remote_backups() {
    local remote_path_escaped=$(printf '%q' "${REMOTE_PATH}")
    local remote_cmd_template
    read -r -d '' remote_cmd_template <<'EOF' || true
dir=__REMOTE_DIR__
[ ! -d "$dir" ] && exit 0
for file in "$dir"/*.sql "$dir"/*.sql.gz "$dir"/*.sql.gz.enc; do
    [ -f "$file" ] || continue
    if date -r "$file" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
        created=$(date -r "$file" "+%Y-%m-%d %H:%M:%S")
    elif stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" >/dev/null 2>&1; then
        created=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file")
    elif stat -c "%y" "$file" >/dev/null 2>&1; then
        created=$(stat -c "%y" "$file" | cut -d'.' -f1)
    else
        created="Inconnue"
    fi
    printf "%s|%s\n" "$(basename "$file")" "$created"
done
EOF
    local remote_cmd="${remote_cmd_template//__REMOTE_DIR__/${remote_path_escaped}}"
    local remote_output exit_code
    if [[ "${REMOTE_AUTH_METHOD}" == "key" ]]; then
        remote_output=$(ssh -p "${REMOTE_PORT}" -i "${REMOTE_SSH_KEY}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${REMOTE_USER}@${REMOTE_HOST}" "${remote_cmd}" 2>>"${log_file}")
        exit_code=$?
    else
        remote_output=$(sshpass -p "${REMOTE_PASSWORD}" ssh -p "${REMOTE_PORT}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "${REMOTE_USER}@${REMOTE_HOST}" "${remote_cmd}" 2>>"${log_file}")
        exit_code=$?
    fi
    (( exit_code != 0 )) && { log_error "Impossible de lister les sauvegardes distantes"; return 1; }
    [[ -z "$remote_output" ]] && { echo "Aucune sauvegarde distante trouvée."; return 0; }

    local -a seen_files=()
    local count=0
    local sorted=$(printf '%s\n' "$remote_output" | sort -t'|' -k2,2r -k1)

    while IFS='|' read -r file created; do
        [[ -n "$file" ]] || continue
        # FIX: Vérifier si le tableau est vide AVANT d'accéder à ${seen_files[*]}
        local is_duplicate=0
        if [[ ${#seen_files[@]} -gt 0 ]]; then
            for seen in "${seen_files[@]}"; do
                if [[ "$seen" == "$file" ]]; then
                    is_duplicate=1
                    break
                fi
            done
        fi

        [[ $is_duplicate -eq 1 ]] && continue

        seen_files+=("$file")
        local name=$(backup_display_name "$file")
        (( count == 0 )) && print_backup_table_header
        print_backup_table_row "$name" "${created:-Inconnue}" "$file"
        (( count++ ))
    done <<< "$sorted"

    (( count == 0 )) && echo "Aucune sauvegarde distante trouvée."
    return 0
}

# ============================================================================
# Tester la connexion distante
# ============================================================================
test_remote_connection() {
    log_info "Test de la connexion distante..."

    if [[ -z "${REMOTE_HOST}" ]]; then
        log_error "Hôte distant non configuré"
        return 1
    fi

    local ssh_cmd
    if [[ "${REMOTE_AUTH_METHOD}" == "key" ]]; then
        if [[ ! -f "${REMOTE_SSH_KEY}" ]]; then
            log_error "Clé SSH introuvable : ${REMOTE_SSH_KEY}"
            return 1
        fi
        ssh_cmd="ssh -p ${REMOTE_PORT} -i ${REMOTE_SSH_KEY} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=10 \
                 -o LogLevel=ERROR"
    else
        if ! command -v sshpass &> /dev/null; then
            log_error "sshpass introuvable"
            return 1
        fi
        ssh_cmd="sshpass -p ${REMOTE_PASSWORD} ssh -p ${REMOTE_PORT} \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=10 \
                 -o LogLevel=ERROR"
    fi

    if ${ssh_cmd} "${REMOTE_USER}@${REMOTE_HOST}" "echo 'Connexion réussie'" 2>> "${log_file}"; then
        log_success "Test de connexion distante réussi"
        return 0
    else
        log_error "Échec du test de connexion distante"
        return 1
    fi
}
