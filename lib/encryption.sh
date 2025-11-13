#!/bin/bash

# ============================================================================
# Module de Chiffrement
# ============================================================================
# Gère le chiffrement et le déchiffrement de fichiers avec AES-256-CBC
# ============================================================================

# ============================================================================
# Chiffrer un fichier avec AES-256-CBC
# ============================================================================
encrypt_file() {
    local input_file="$1"
    local output_file="${input_file}.enc"

    if [[ ! -f "${input_file}" ]]; then
        log_error "Fichier d'entrée introuvable : ${input_file}"
        return 1
    fi

    if [[ ! -f "${ENCRYPTION_KEY_FILE}" ]]; then
        log_error "Fichier de clé de chiffrement introuvable : ${ENCRYPTION_KEY_FILE}"
        return 1
    fi

    # Vérifier si openssl est disponible
    if ! command -v openssl &> /dev/null; then
        log_error "Commande openssl introuvable. Veuillez installer OpenSSL."
        return 1
    fi

    # Lire la clé de chiffrement
    local encryption_key=$(cat "${ENCRYPTION_KEY_FILE}")

    # Chiffrer le fichier avec AES-256-CBC
    # -pbkdf2 : Utiliser PBKDF2 pour la dérivation de clé
    # -iter 100000 : 100000 itérations pour PBKDF2
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "${input_file}" \
        -out "${output_file}" \
        -k "${encryption_key}" 2>> "${log_file}"

    if [[ $? -ne 0 ]]; then
        log_error "Échec du chiffrement"
        return 1
    fi

    # Vérifier que le fichier chiffré a été créé
    if [[ ! -f "${output_file}" ]]; then
        log_error "Le fichier chiffré n'a pas été créé"
        return 1
    fi

    local encrypted_size=$(du -h "${output_file}" | cut -f1)
    log_info "Fichier chiffré : ${output_file} (${encrypted_size})"

    return 0
}

# ============================================================================
# Déchiffrer un fichier avec AES-256-CBC
# ============================================================================
decrypt_file() {
    local input_file="$1"
    local output_file="$2"

    if [[ ! -f "${input_file}" ]]; then
        log_error "Fichier d'entrée introuvable : ${input_file}"
        return 1
    fi

    if [[ ! -f "${ENCRYPTION_KEY_FILE}" ]]; then
        log_error "Fichier de clé de chiffrement introuvable : ${ENCRYPTION_KEY_FILE}"
        return 1
    fi

    # Vérifier si openssl est disponible
    if ! command -v openssl &> /dev/null; then
        log_error "Commande openssl introuvable. Veuillez installer OpenSSL."
        return 1
    fi

    # Lire la clé de chiffrement
    local encryption_key=$(cat "${ENCRYPTION_KEY_FILE}")

    # Déchiffrer le fichier avec AES-256-CBC
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "${input_file}" \
        -out "${output_file}" \
        -k "${encryption_key}" 2>> "${log_file}"

    if [[ $? -ne 0 ]]; then
        log_error "Échec du déchiffrement. Vérifiez si la clé de chiffrement est correcte."
        return 1
    fi

    # Vérifier que le fichier déchiffré a été créé
    if [[ ! -f "${output_file}" ]]; then
        log_error "Le fichier déchiffré n'a pas été créé"
        return 1
    fi

    local decrypted_size=$(du -h "${output_file}" | cut -f1)
    log_info "Fichier déchiffré : ${output_file} (${decrypted_size})"

    return 0
}

# ============================================================================
# Vérifier si un fichier est chiffré
# ============================================================================
is_encrypted() {
    local file_path="$1"

    # Vérifier si le fichier a l'extension .enc
    if [[ "${file_path}" == *.enc ]]; then
        return 0
    fi

    # Vérifier la signature du fichier (les fichiers chiffrés OpenSSL commencent par "Salted__")
    if [[ -f "${file_path}" ]]; then
        local header=$(head -c 8 "${file_path}" 2>/dev/null)
        if [[ "${header}" == "Salted__" ]]; then
            return 0
        fi
    fi

    return 1
}

# ============================================================================
# Rotation de la clé de chiffrement
# ============================================================================
rotate_encryption_key() {
    local backup_dir="${BACKUP_DIR}"

    log_warning "Rotation de la clé de chiffrement..."

    # Sauvegarder l'ancienne clé
    local old_key_backup="${ENCRYPTION_KEY_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${ENCRYPTION_KEY_FILE}" "${old_key_backup}"
    log_info "Ancienne clé sauvegardée dans : ${old_key_backup}"

    # Générer une nouvelle clé
    openssl rand -base64 32 > "${ENCRYPTION_KEY_FILE}"
    chmod 600 "${ENCRYPTION_KEY_FILE}"
    log_success "Nouvelle clé de chiffrement générée"

    echo "ATTENTION : Les anciennes sauvegardes chiffrées ne peuvent pas être déchiffrées avec la nouvelle clé !"
    echo "L'ancienne clé a été sauvegardée dans : ${old_key_backup}"
    echo "Conservez l'ancienne clé pour déchiffrer les sauvegardes existantes."

    return 0
}

# ============================================================================
# Rechiffrer un fichier avec une nouvelle clé
# ============================================================================
reencrypt_file() {
    local input_file="$1"
    local old_key_file="$2"
    local new_key_file="${ENCRYPTION_KEY_FILE}"

    if [[ ! -f "${input_file}" ]]; then
        log_error "Fichier d'entrée introuvable : ${input_file}"
        return 1
    fi

    if [[ ! -f "${old_key_file}" ]]; then
        log_error "Ancien fichier de clé introuvable : ${old_key_file}"
        return 1
    fi

    log_info "Rechiffrement du fichier avec la nouvelle clé..."

    # Déchiffrer avec l'ancienne clé
    local temp_decrypted="${input_file}.tmp.decrypted"
    local old_key=$(cat "${old_key_file}")

    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "${input_file}" \
        -out "${temp_decrypted}" \
        -k "${old_key}" 2>> "${log_file}"

    if [[ $? -ne 0 ]]; then
        log_error "Échec du déchiffrement avec l'ancienne clé"
        rm -f "${temp_decrypted}"
        return 1
    fi

    # Chiffrer avec la nouvelle clé
    local new_key=$(cat "${new_key_file}")
    local temp_encrypted="${input_file}.tmp.encrypted"

    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "${temp_decrypted}" \
        -out "${temp_encrypted}" \
        -k "${new_key}" 2>> "${log_file}"

    if [[ $? -ne 0 ]]; then
        log_error "Échec du chiffrement avec la nouvelle clé"
        rm -f "${temp_decrypted}" "${temp_encrypted}"
        return 1
    fi

    # Remplacer le fichier original
    mv "${temp_encrypted}" "${input_file}"
    rm -f "${temp_decrypted}"

    log_success "Fichier rechiffré avec succès"
    return 0
}

# ============================================================================
# Vérifier la clé de chiffrement
# ============================================================================
verify_encryption_key() {
    if [[ ! -f "${ENCRYPTION_KEY_FILE}" ]]; then
        log_error "Fichier de clé de chiffrement introuvable : ${ENCRYPTION_KEY_FILE}"
        return 1
    fi

    local key_length=$(wc -c < "${ENCRYPTION_KEY_FILE}" | tr -d ' ')

    if [[ ${key_length} -lt 32 ]]; then
        log_error "La clé de chiffrement est trop courte (moins de 32 octets)"
        return 1
    fi

    log_info "Clé de chiffrement vérifiée"
    return 0
}

# ============================================================================
# Tester le chiffrement/déchiffrement
# ============================================================================
test_encryption() {
    log_info "Test du chiffrement/déchiffrement..."

    local test_file="/tmp/dbbackup_test_$(date +%s).txt"
    local test_content="Test de chiffrement DBBackup : $(date)"

    # Créer un fichier de test
    echo "${test_content}" > "${test_file}"

    # Chiffrer
    if ! encrypt_file "${test_file}"; then
        rm -f "${test_file}"
        return 1
    fi

    # Déchiffrer
    local decrypted_file="${test_file}.decrypted"
    if ! decrypt_file "${test_file}.enc" "${decrypted_file}"; then
        rm -f "${test_file}" "${test_file}.enc"
        return 1
    fi

    # Vérifier le contenu
    local decrypted_content=$(cat "${decrypted_file}")
    if [[ "${test_content}" == "${decrypted_content}" ]]; then
        log_success "Test de chiffrement/déchiffrement réussi"
        rm -f "${test_file}" "${test_file}.enc" "${decrypted_file}"
        return 0
    else
        log_error "Échec du test de chiffrement/déchiffrement : contenu différent"
        rm -f "${test_file}" "${test_file}.enc" "${decrypted_file}"
        return 1
    fi
}
