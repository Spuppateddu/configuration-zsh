#!/usr/bin/env bash
# Installs Oh My Zsh + plugins, points ~/.zshrc at ./zshrc, makes zsh the login
# shell. Idempotent.
#
# Usage: ./install.sh [--dry-run] [--no-login-shell]  (DRY_RUN env also honoured)
#   --dry-run          print every step, touch nothing
#   --no-login-shell   wire the config but leave the login shell alone. What
#                      best-linux-environment passes when you chose bash: both
#                      shell config repos may be on the machine, and only one of
#                      them owns `chsh` — otherwise every ./boot.sh would set the
#                      login shell back to whichever installer ran last.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reject unknown args rather than ignoring them — a typo'd `--dryrun` silently
# performing a real install is the worst outcome.
usage() {
    printf 'Usage: %s [--dry-run] [--no-login-shell]\n' \
        "$(basename "${BASH_SOURCE[0]}")" >&2
    exit 2
}
SET_LOGIN_SHELL=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true ;;
        --no-login-shell) SET_LOGIN_SHELL=false ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage ;;
    esac
    shift
done
# Normalise to true/false once — every check below is a literal `== true`, so
# DRY_RUN=1 would otherwise read as false and install for real.
case "${DRY_RUN:-}" in
    ""|[Ff]alse|FALSE|0|[Nn]o|NO|[Oo]ff|OFF) DRY_RUN=false ;;
    [Tt]rue|TRUE|1|[Yy]es|YES|[Oo]n|ON)      DRY_RUN=true ;;
    *) printf 'Invalid DRY_RUN: %s\nUse DRY_RUN=true or DRY_RUN=false.\n' \
           "$DRY_RUN" >&2; exit 2 ;;
esac
# Where zsh actually reads .zshrc from: with ZDOTDIR set it never reads
# $HOME/.zshrc, so wiring that would touch a file nothing loads.
ZDOT="${ZDOTDIR:-$HOME}"
# Set when the rc file was deliberately left untouched — changes the closing note.
WIRING_BLOCKED=false
# Whether the rc file predates this run — tells the user's own config apart from
# the template Oh My Zsh writes when none exists.
ZSHRC_PREEXISTING=false
[[ -e "$ZDOT/.zshrc" ]] && ZSHRC_PREEXISTING=true

# ── Self-contained helpers (no external lib — this repo installs alone) ──────
if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi
step()  { printf '%s▸%s %s\n' "$C_BLUE"  "$C_OFF" "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
skip()  { printf '%s·%s %s%s%s\n' "$C_DIM" "$C_OFF" "$C_DIM" "$*" "$C_OFF"; }
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
title() { printf '\n%s══ %s ══%s\n' "$C_BOLD" "$*" "$C_OFF"; }
run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '%s  would run:%s %s\n' "$C_DIM" "$C_OFF" "$*"
    else
        "$@"
    fi
}
has_cmd() { command -v "$1" >/dev/null 2>&1; }
# Root needs no sudo (containers often lack the binary entirely); otherwise it
# needs a terminal or cached credentials, so cron runs never hang on a prompt.
can_sudo() {
    [[ $EUID -eq 0 ]] && return 0
    has_cmd sudo || return 1
    [[ -t 0 ]] || sudo -n true 2>/dev/null
}
# Prefix for privileged commands. Unquoted at call sites so root expands to
# nothing rather than an empty argv[0].
SUDO=sudo
[[ $EUID -eq 0 ]] && SUDO=""
# `sudo ./install.sh` would configure root's account instead — every path here
# is $HOME-derived. Plain root (container, SUDO_USER unset) still works.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    printf 'Run this as %s, not with sudo — it configures $HOME (now %s).\n' \
        "$SUDO_USER" "$HOME" >&2
    printf 'Package installs escalate on their own. Re-run: ./install.sh\n' >&2
    exit 2
fi
# Install what's missing via apt or brew. Our packages are named after their
# commands, so has_cmd suffices; a failure only warns and the setup continues.
pkg_ensure() {
    local pkg missing=()
    for pkg in "$@"; do has_cmd "$pkg" || missing+=("$pkg"); done
    [[ ${#missing[@]} -eq 0 ]] && { skip "nothing to install (${*})."; return 0; }
    if [[ "$DRY_RUN" == true ]]; then
        printf '%s  would install:%s %s\n' "$C_DIM" "$C_OFF" "${missing[*]}"; return 0
    fi
    if has_cmd apt-get; then
        if ! can_sudo; then
            warn "No root privileges (no sudo, or non-interactive) — skipped install: ${missing[*]}"
            return 0
        fi
        step "apt: installing ${missing[*]}"
        $SUDO apt-get update -qq || warn "apt update reported errors — continuing."
        $SUDO apt-get install -y "${missing[@]}" \
            || warn "apt install failed — install yourself: ${missing[*]}"
    elif has_cmd brew; then
        step "brew: installing ${missing[*]}"
        brew install "${missing[@]}" \
            || warn "brew install failed — install yourself: ${missing[*]}"
    else
        warn "No apt-get or brew found — install yourself: ${missing[*]}"
    fi
}
clone_or_pull() {
    local url="$1" dest="$2"
    if [[ -d "$dest/.git" ]]; then
        run git -C "$dest" pull --ff-only --quiet || warn "Could not pull $dest — leaving as-is."
    elif [[ -e "$dest" ]]; then
        warn "$dest exists but is not a git checkout — leaving untouched."
    else
        step "Cloning $url → $dest"
        run git clone --quiet "$url" "$dest"
    fi
}
# Absolute path with the *directory* symlinks resolved, so two spellings of one
# file compare equal. `cd -P` not `readlink -f`, which macOS lacks.
canon_path() {
    local p="$1" d b
    d="$(dirname -- "$p")"; b="$(basename -- "$p")"
    if [[ -d "$d" ]]; then printf '%s/%s\n' "$(cd -P -- "$d" && pwd)" "$b"
    else printf '%s\n' "$p"; fi
}

# already_sources <path> <rc-file> — true however the line was spelled, since
# candidates are canonicalised: the repo is reachable under two names.
already_sources() {
    local target="$1" file="$2" want raw path
    [[ -f "$file" ]] || return 1
    want="$(canon_path "$target")"
    while IFS= read -r raw; do
        path="$raw"
        # No shell expands the rc file here, so handle the three spellings by
        # hand. Anything still relative is unresolvable — skip it.
        case "$path" in
            "~/"*)       path="$HOME/${path#\~/}" ;;
            '$HOME/'*)   path="$HOME/${path#\$HOME/}" ;;
            '${HOME}/'*) path="$HOME/${path#\$\{HOME\}/}" ;;
        esac
        [[ "$path" == /* ]] || continue
        [[ "$(canon_path "$path")" == "$want" ]] && return 0
    done < <(awk '
        # Print the argument of every source/. command, one per line. Anchored
        # at a command position, so a path inside an alias is not collected.
        { line = $0
          sub(/^[[:space:]]+/, "", line)
          if (line ~ /^#/) next
          if (match(line, /(^|[;&|(])[[:space:]]*(source|\.)[[:space:]]+["\047]?[^"\047[:space:];&|)]+/)) {
              tok = substr(line, RSTART, RLENGTH)
              sub(/^.*(source|\.)[[:space:]]+["\047]?/, "", tok)
              print tok
          }
        }' "$file")
    return 1
}

# ensure_source_line <path-to-source> <rc-file> — appends by default, replaces
# only the stock Oh My Zsh template. Either way the original is backed up first.
ensure_source_line() {
    local target="$1" file="$2"
    # Quoted, so a repo cloned to a path with spaces still sources.
    local line="source \"$target\""
    if already_sources "$target" "$file"; then
        skip "$file already wired."
        return
    fi
    # Our zshrc loads Oh My Zsh itself, so appending to an rc that already does
    # would load it twice. Only the user's own config earns this deference.
    if [[ "$ZSHRC_PREEXISTING" == true ]] && [[ -f "$file" ]] && grep -q 'oh-my-zsh\.sh' "$file"; then
        WIRING_BLOCKED=true
        warn "$file already sources Oh My Zsh — appending would load it twice."
        warn "Remove that block (with its ZSH_THEME/plugins= lines) from $file,"
        warn "then re-run, or wire it by hand with: $line"
        return
    fi
    # The template is replaced, not appended to — appending would leave its own
    # oh-my-zsh.sh line behind.
    local mode=append
    if [[ "$ZSHRC_PREEXISTING" == false && -s "$file" ]] && grep -q 'oh-my-zsh\.sh' "$file"; then
        mode=replace
    fi
    # Under --dry-run nothing is touched, so no message may claim otherwise.
    local say_append=appending say_replace="replacing it"
    if [[ "$DRY_RUN" == true ]]; then
        say_append="would append"; say_replace="would replace it"
    fi
    if [[ -s "$file" ]]; then
        # One stable backup, written only the first time — re-copying would bury
        # the pristine original under an already-wired copy.
        local backup="$file.pre-zsh-config.backup"
        case "$mode" in
            replace) step "$file is the stock Oh My Zsh template — $say_replace" ;;
            *)       step "$file exists — $say_append" ;;
        esac
        if [[ -e "$backup" ]]; then
            skip "backup already exists at $backup — keeping it."
        elif [[ "$DRY_RUN" == true ]]; then
            printf '%s  would back up:%s %s → %s\n' "$C_DIM" "$C_OFF" "$file" "$backup"
        else
            step "Backing up to $backup"
            cp "$file" "$backup"
        fi
    fi
    if [[ "$DRY_RUN" == true ]]; then
        printf '%s  would %s:%s %s → %s\n' "$C_DIM" "$mode" "$C_OFF" "$line" "$file"
        return
    fi
    if [[ "$mode" == replace ]]; then
        printf '%s\n' "$line" > "$file"
    else
        # Don't glue onto a file whose last line has no newline.
        [[ -s "$file" && -n "$(tail -c1 "$file")" ]] && printf '\n' >> "$file"
        printf '%s\n' "$line" >> "$file"
    fi
    ok "wired $file"
}

# ── Install ──────────────────────────────────────────────────────────────────
title "Zsh"

pkg_ensure zsh git curl

ZSH_DIR="$HOME/.oh-my-zsh"
# Not ${ZSH_CUSTOM:-...}: Oh My Zsh looks in $ZSH/custom regardless, so an
# inherited value would clone the plugins where nothing loads them.
ZSH_CUSTOM="$ZSH_DIR/custom"

# 1. Oh My Zsh, unattended. Fetched to disk first (a dropped pipe would run a
#    truncated script) and pinned to a SHA — override with OMZ_REF.
OMZ_REF="${OMZ_REF:-7ea697fd8138550ddf7262456d412f0dcd1cbf84}"
OMZ_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/$OMZ_REF/tools/install.sh"
OMZ_SH="$ZSH_DIR/oh-my-zsh.sh"
# Whether the framework is in place — step 2 must not clone into $ZSH_DIR first.
OMZ_INSTALLED=false
# Probe the entrypoint, not the directory: upstream's installer aborts if
# $ZSH_DIR exists, so a half-finished one locks installation out for good.
if [[ -f "$OMZ_SH" ]]; then
    skip "Oh My Zsh already installed."
    OMZ_INSTALLED=true
elif [[ "$DRY_RUN" == true ]]; then
    printf '%s  would install:%s Oh My Zsh from %s\n' "$C_DIM" "$C_OFF" "$OMZ_URL"
elif [[ -d "$ZSH_DIR" ]] && ! rmdir "$ZSH_DIR" 2>/dev/null; then
    warn "$ZSH_DIR exists but holds no oh-my-zsh.sh — a half-finished install."
    warn "Upstream's installer refuses to overwrite it. Remove it and re-run:"
    warn "    rm -rf $ZSH_DIR"
else
    step "Installing Oh My Zsh (unattended, ref $OMZ_REF)"
    omz_installer="$(mktemp -t omz-install.XXXXXX)"
    # INT/TERM must abort, not just tidy up, or Ctrl-C falls through into the
    # rest of the setup with no framework in place.
    trap 'rm -f -- "$omz_installer"' EXIT
    trap 'rm -f -- "$omz_installer"; exit 130' INT TERM
    if ! curl -fsSL "$OMZ_URL" -o "$omz_installer" || [[ ! -s "$omz_installer" ]]; then
        warn "Could not download the Oh My Zsh installer from $OMZ_URL — skipping."
    # ZSH="$ZSH_DIR" is not redundant: upstream installs to whatever $ZSH the
    # environment exports, and our own zshrc exports it.
    elif ZSH="$ZSH_DIR" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$omz_installer" --unattended; then
        ok "Oh My Zsh installed."
        OMZ_INSTALLED=true
    else
        warn "Oh My Zsh install failed — continuing with the rest of the setup."
    fi
    rm -f -- "$omz_installer"
    trap - EXIT INT TERM
fi

# 2. External plugins the config expects. "name url" pairs, not an associative
#    array — macOS still ships bash 3.2, which has no `declare -A`.
PLUGINS=(
    "zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions"
    "zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting"
    "zsh-history-substring-search https://github.com/zsh-users/zsh-history-substring-search"
)
# Gated on step 1: git creates the parents, so cloning after a failed install
# would conjure the $ZSH_DIR that locks every later re-run out.
if [[ "$OMZ_INSTALLED" == true || "$DRY_RUN" == true ]]; then
    for entry in "${PLUGINS[@]}"; do
        clone_or_pull "${entry#* }" "$ZSH_CUSTOM/plugins/${entry%% *}"
    done
else
    warn "Skipping plugins — Oh My Zsh is not in place to hold them."
fi

# 3. Point the rc file at this repo, wherever it was cloned — zshrc resolves its
#    own paths from $0. A set-but-missing ZDOTDIR needs creating first.
[[ -d "$ZDOT" ]] || run mkdir -p "$ZDOT"
ensure_source_line "$REPO/zshrc" "$ZDOT/.zshrc"

# 4. Make zsh the login shell.
#
# `chsh` changing your own entry goes through PAM, which wants your password — so
# it needs either a terminal to ask on or root. A plain `[[ -t 0 ]]` guard is not
# enough, and getting that wrong is silent in the worst way: run under
# best-linux-environment, stdin is /dev/null (no installer may stop the run to ask
# a question), so the guard was false, chsh was skipped, and the shell choice you
# had just been asked for did nothing. The next terminal was still the old shell.
#
# So try the ways this can work, in order of what is actually available:
#   root          no PAM prompt at all
#   cached sudo   `sudo -n` — the case that matters. A ./setup.sh run has already
#                 used sudo for the package installs, so its credentials are warm
#                 and this goes through with no prompt and no terminal.
#   a terminal    running this repo on its own: chsh asks, you type it
# and only when none of those hold, print the command to run by hand.
set_login_shell() {
    local target="$1" user; user="$(id -un)"
    if [[ $EUID -eq 0 ]]; then
        run chsh -s "$target" "$user"
    elif has_cmd sudo && sudo -n true 2>/dev/null; then
        run sudo -n chsh -s "$target" "$user"
    elif [[ -t 0 ]]; then
        run chsh -s "$target"
    else
        return 1
    fi
}

zsh_path="$(command -v zsh || true)"
# id -un, not $USER — $USER is unset under cron/systemd and set -u would abort.
login_shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7 || true)"
[[ -z "$login_shell" ]] && login_shell="${SHELL:-}"   # getent is Linux-only
if [[ "$SET_LOGIN_SHELL" != true ]]; then
    skip "--no-login-shell — config wired, login shell left as ${login_shell:-unknown}."
elif [[ -z "$zsh_path" ]]; then
    warn "zsh not found — skipping login-shell step. Install zsh, then re-run."
elif [[ "$login_shell" == "$zsh_path" ]]; then
    skip "zsh already the login shell."
elif set_login_shell "$zsh_path"; then
    ok "zsh is now your login shell (was ${login_shell:-unknown})."
    # Spelled out because this is the thing people file a bug about — "I chose
    # zsh, chsh worked, and my next terminal was STILL the old shell".
    #
    # chsh changes /etc/passwd. Almost nothing reads /etc/passwd. What terminals
    # read is $SHELL, and $SHELL is set once, by PAM, when your desktop session
    # logs in — from whatever /etc/passwd said AT THAT MOMENT. Change it
    # afterwards and the running session never hears about it: your window
    # manager still holds the old value, and every terminal it spawns inherits it.
    #
    # Measured on Alacritty 0.16: it prefers $SHELL and only falls back to the
    # passwd entry when $SHELL is unset. So a brand-new window opened from the
    # same session is still the old shell. That is not a failed chsh — it is a
    # session that has not logged in again yet.
    warn "chsh is done, but it only takes effect at your next LOGIN."
    warn "\$SHELL is still ${SHELL:-unset} in this session, and terminals read that —"
    warn "so even a brand-new window keeps the old shell until you log out."
    warn "  now, in this shell   : exec zsh -l"
    warn "  new tmux panes       : tmux kill-server"
    warn "  everything, properly : log out and back in"
else
    warn "Could not change the login shell: no terminal to ask for a password on,"
    warn "and no cached sudo credentials. Run it yourself:"
    warn "    chsh -s $zsh_path"
fi

# Missing here means step 1 failed and zshrc degrades to bare aliases — say so
# now rather than let the next shell be a surprise.
if [[ "$DRY_RUN" != true && ! -f "$OMZ_SH" ]]; then
    warn "Oh My Zsh is not installed — theme, plugins and completions stay off."
    warn "Sort the network/permissions issue out, then re-run ./install.sh."
fi

# Reload: a parent shell can't be re-sourced from this subprocess, so guide it.
if [[ "$WIRING_BLOCKED" == true ]]; then
    warn "Deps installed, but ~/.zshrc was left untouched — see the note above."
else
    warn "Reload zsh to apply the config: run 'exec zsh' or open a new terminal."
    ok "Zsh ready."
fi
