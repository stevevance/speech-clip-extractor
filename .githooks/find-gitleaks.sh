# Sourced by the hooks: sets GITLEAKS to the gitleaks program, or exits with a message.
# Git apps and GUI tools may not have Homebrew on their PATH, so check its folders too.
GITLEAKS=$(command -v gitleaks 2>/dev/null)
for candidate in /opt/homebrew/bin/gitleaks /usr/local/bin/gitleaks; do
  [ -z "$GITLEAKS" ] && [ -x "$candidate" ] && GITLEAKS=$candidate
done
if [ -z "$GITLEAKS" ]; then
  echo "Secret check: gitleaks isn't installed, so nothing was checked and this was blocked." >&2
  echo "Install it with: brew install gitleaks" >&2
  exit 1
fi
