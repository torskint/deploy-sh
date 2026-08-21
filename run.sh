#!/usr/bin/env bash
#
# run.sh -- Telecharge la derniere version de deploy.sh depuis le repo GitHub
# prive et l'execute immediatement, avec le meme token GitHub.
#
# Contrairement a deploy.sh, ce script ne se supprime pas : il reste sur le
# serveur pour pouvoir relancer un deploiement a tout moment, en recuperant
# systematiquement la version la plus recente de deploy.sh (inutile de le
# retelecharger manuellement apres chaque modification).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration a personnaliser (doit correspondre au repo qui heberge deploy.sh)
# ---------------------------------------------------------------------------
DEPLOY_REPO_OWNER="torskint"
DEPLOY_REPO_NAME="deploy-sh"
DEPLOY_FILE_PATH="deploy.sh"
DEPLOY_BRANCH="main"

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

DEPLOY_SCRIPT_TMP=""
cleanup() {
    if [ -n "$DEPLOY_SCRIPT_TMP" ] && [ -f "$DEPLOY_SCRIPT_TMP" ]; then
        rm -f -- "$DEPLOY_SCRIPT_TMP"
    fi
}
trap cleanup EXIT

require_cmd curl

# ---------------------------------------------------------------------------
# Authentification GitHub
# ---------------------------------------------------------------------------
if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -r -s -p "Token GitHub (avec acces aux repos prives concernes) : " GITHUB_TOKEN
    echo ""
fi
[ -n "$GITHUB_TOKEN" ] || err "un token GitHub est requis."

# ---------------------------------------------------------------------------
# Telechargement de la derniere version de deploy.sh
# ---------------------------------------------------------------------------
info "Telechargement de la derniere version de ${DEPLOY_FILE_PATH}..."

deploy_url="${GITHUB_API}/repos/${DEPLOY_REPO_OWNER}/${DEPLOY_REPO_NAME}/contents/${DEPLOY_FILE_PATH}?ref=${DEPLOY_BRANCH}"

DEPLOY_SCRIPT_TMP=$(mktemp)
curl -fsSL \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.raw" \
    "$deploy_url" -o "$DEPLOY_SCRIPT_TMP" \
    || err "impossible de telecharger ${DEPLOY_FILE_PATH} depuis GitHub (${deploy_url})."

[ -s "$DEPLOY_SCRIPT_TMP" ] || err "le fichier telecharge est vide."
chmod +x "$DEPLOY_SCRIPT_TMP"

# ---------------------------------------------------------------------------
# Execution avec le meme token (evite une nouvelle demande interactive)
# ---------------------------------------------------------------------------
info "Execution de ${DEPLOY_FILE_PATH}..."
GITHUB_TOKEN="$GITHUB_TOKEN" bash "$DEPLOY_SCRIPT_TMP"
