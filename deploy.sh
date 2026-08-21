#!/usr/bin/env bash
#
# deploy.sh -- Deploiement automatise d'un site Laravel choisi parmi une liste
# de depots GitHub prives, organisee par categories via un fichier de config
# JSON heberge sur un repo GitHub prive dedie.
#
# A la fin d'un deploiement reussi, ce script se supprime lui-meme.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration a personnaliser
# ---------------------------------------------------------------------------
CONFIG_REPO_OWNER="torskint"
CONFIG_REPO_NAME="deploy-sh"
CONFIG_FILE_PATH="repos.json"
CONFIG_BRANCH="main"

PUBLIC_HTML_DIR="${PUBLIC_HTML_DIR:-$HOME/public_html}"

GITHUB_API="https://api.github.com"

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
err() {
    echo "Erreur: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "la commande '$1' est requise mais introuvable dans le PATH."
}

TMP_CLONE_DIR=""
cleanup() {
    if [ -n "$TMP_CLONE_DIR" ] && [ -d "$TMP_CLONE_DIR" ]; then
        rm -rf -- "$TMP_CLONE_DIR"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Prerequis
# ---------------------------------------------------------------------------
require_cmd git
require_cmd curl
require_cmd jq
require_cmd php
require_cmd composer

# ---------------------------------------------------------------------------
# 2. Authentification GitHub
# ---------------------------------------------------------------------------
if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -r -s -p "Token GitHub (avec acces aux repos prives concernes) : " GITHUB_TOKEN
    echo ""
fi
[ -n "$GITHUB_TOKEN" ] || err "un token GitHub est requis."

# ---------------------------------------------------------------------------
# 3. Recuperation de la config (repo prive)
# ---------------------------------------------------------------------------
info "Recuperation de la configuration des repos..."

config_url="${GITHUB_API}/repos/${CONFIG_REPO_OWNER}/${CONFIG_REPO_NAME}/contents/${CONFIG_FILE_PATH}?ref=${CONFIG_BRANCH}"

config_json=$(curl -fsSL \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "$config_url") || err "impossible de recuperer le fichier de config depuis GitHub (${config_url})."

echo "$config_json" | jq empty >/dev/null 2>&1 || err "le fichier de config recupere n'est pas un JSON valide."

# ---------------------------------------------------------------------------
# 4. Menu categories
# ---------------------------------------------------------------------------
mapfile -t categories < <(echo "$config_json" | jq -r 'keys[]')

[ "${#categories[@]}" -gt 0 ] || err "aucune categorie trouvee dans le fichier de config."

echo ""
echo "Categories disponibles :"
for i in "${!categories[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${categories[$i]}"
done
echo ""

read -r -p "Choisissez une categorie [1-${#categories[@]}]: " cat_choice

case "$cat_choice" in
    ''|*[!0-9]*) err "choix invalide.";;
esac
[ "$cat_choice" -ge 1 ] && [ "$cat_choice" -le "${#categories[@]}" ] || err "choix hors limites."

selected_category="${categories[$((cat_choice - 1))]}"

# ---------------------------------------------------------------------------
# 5. Menu repos de la categorie choisie
# ---------------------------------------------------------------------------
mapfile -t repo_names < <(echo "$config_json" | jq -r --arg cat "$selected_category" '.[$cat][].name')

[ "${#repo_names[@]}" -gt 0 ] || err "aucun repo trouve dans la categorie '${selected_category}'."

echo ""
echo "Repos disponibles dans '${selected_category}' :"
for i in "${!repo_names[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${repo_names[$i]}"
done
echo ""

read -r -p "Choisissez un repo [1-${#repo_names[@]}]: " repo_choice

case "$repo_choice" in
    ''|*[!0-9]*) err "choix invalide.";;
esac
[ "$repo_choice" -ge 1 ] && [ "$repo_choice" -le "${#repo_names[@]}" ] || err "choix hors limites."

repo_index=$((repo_choice - 1))
selected_repo_name="${repo_names[$repo_index]}"
repo_url=$(echo "$config_json" | jq -r --arg cat "$selected_category" --argjson idx "$repo_index" '.[$cat][$idx].repo_url')
repo_branch=$(echo "$config_json" | jq -r --arg cat "$selected_category" --argjson idx "$repo_index" '.[$cat][$idx].branch')

[ -n "$repo_url" ] && [ "$repo_url" != "null" ] || err "repo_url manquant pour '${selected_repo_name}'."
[ -n "$repo_branch" ] && [ "$repo_branch" != "null" ] || err "branch manquante pour '${selected_repo_name}'."

info "Repo selectionne : ${selected_repo_name} (${repo_url}, branche ${repo_branch})"

# ---------------------------------------------------------------------------
# 6. Clonage
# ---------------------------------------------------------------------------
TMP_CLONE_DIR=$(mktemp -d)

clone_url="$repo_url"
case "$repo_url" in
    https://*)
        clone_url="https://${GITHUB_TOKEN}@${repo_url#https://}"
        ;;
esac

info "Clonage du repo dans un repertoire temporaire..."
git clone --branch "$repo_branch" --depth 1 -- "$clone_url" "$TMP_CLONE_DIR" \
    || err "echec du clonage de '${selected_repo_name}'."

[ -f "${TMP_CLONE_DIR}/artisan" ] || err "le repo clone ne semble pas etre un projet Laravel (fichier 'artisan' introuvable)."

# ---------------------------------------------------------------------------
# 7. Installation Composer
# ---------------------------------------------------------------------------
info "Installation des dependances Composer..."
( cd "$TMP_CLONE_DIR" && composer install --no-dev --optimize-autoloader ) \
    || err "echec de 'composer install'."

# ---------------------------------------------------------------------------
# 8. Gestion .env
# ---------------------------------------------------------------------------
[ -f "${TMP_CLONE_DIR}/.env.example" ] || err "'.env.example' introuvable dans le repo clone."
cp -f "${TMP_CLONE_DIR}/.env.example" "${TMP_CLONE_DIR}/.env"
info ".env cree a partir de .env.example."

# ---------------------------------------------------------------------------
# 9. Confirmation avant ecrasement de public_html/
# ---------------------------------------------------------------------------
mkdir -p "$PUBLIC_HTML_DIR"

echo ""
echo "Le contenu de '${PUBLIC_HTML_DIR}' (fichiers et dossiers, y compris caches) va etre supprime"
echo "puis remplace par le contenu de '${selected_repo_name}'."
read -r -p "Confirmer ? [o/N] " confirm

case "$confirm" in
    [oOyY]|[oO][uU][iI]|[yY][eE][sS]) ;;
    *)
        info "Deploiement annule par l'utilisateur. Le script n'est pas supprime."
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# 10. Deploiement
# ---------------------------------------------------------------------------
info "Nettoyage du contenu de '${PUBLIC_HTML_DIR}'..."
find "$PUBLIC_HTML_DIR" -mindepth 1 -delete

info "Copie du site vers '${PUBLIC_HTML_DIR}'..."
if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' "${TMP_CLONE_DIR}/" "${PUBLIC_HTML_DIR}/"
else
    ( cd "$TMP_CLONE_DIR" && cp -a . "${PUBLIC_HTML_DIR}/" )
    rm -rf -- "${PUBLIC_HTML_DIR}/.git"
fi

# ---------------------------------------------------------------------------
# 11. Post-deploiement Laravel
# ---------------------------------------------------------------------------
info "Nettoyage des caches et configs Laravel..."
(
    cd "$PUBLIC_HTML_DIR"
    php artisan key:generate --force
    php artisan config:clear
    php artisan cache:clear
    php artisan route:clear
    php artisan view:clear
) || err "echec des commandes artisan post-deploiement."

info "Deploiement de '${selected_repo_name}' termine avec succes."

# ---------------------------------------------------------------------------
# 12. Nettoyage (gere par le trap EXIT)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 13. Auto-suppression
# ---------------------------------------------------------------------------
info "Suppression du script de deploiement..."
rm -- "$0"
