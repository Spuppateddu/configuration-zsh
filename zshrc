# Path to your oh-my-zsh installation.
export ZSH=$HOME/.oh-my-zsh

# Directory this file lives in, so the repo works from any clone location.
ZSH_CONFIG_DIR="${0:A:h}"

# Default only — never override a locale the system already set.
export LANG="${LANG:-en_US.UTF-8}"

# -U drops duplicates, so re-sourcing this file doesn't grow PATH.
typeset -U path PATH

# Guarded on the directory existing. Later calls land further left, so call
# order is precedence order (lowest first).
_prepend_path() { [ -d "$1" ] && export PATH="$1:$PATH" }

_prepend_path "$HOME/bin"
# Locally-installed binaries (yazi, fzf, lazygit, temps). Ubuntu adds this from
# ~/.profile, which zsh never reads — without this they don't resolve over SSH.
_prepend_path "$HOME/.local/bin"
# Intel-Homebrew path — absent on Linux and on Apple Silicon.
_prepend_path /usr/local/opt/mysql-client/bin

ZSH_THEME="gnzh"

# nvm, loaded on first use: sourcing nvm.sh costs 100-400ms per shell and most
# shells never run node.
export NVM_DIR="$HOME/.nvm"
_nvm_load() {
    unfunction nvm node npm npx 2>/dev/null
    local dir
    # First hit wins — sourcing both would load two nvm versions over each other.
    for dir in /opt/homebrew/opt/nvm "$NVM_DIR"; do
        [ -s "$dir/nvm.sh" ] && { \. "$dir/nvm.sh"; break; }
    done
    [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \
        \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    return 0
}
for _nvm_cmd in nvm node npm npx; do
    # No `command` prefix: nvm itself is a shell function, which it would skip.
    eval "$_nvm_cmd() { _nvm_load; $_nvm_cmd \"\$@\"; }"
done
unset _nvm_cmd

# Plugins — zsh-syntax-highlighting must stay ahead of history-substring-search.
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search)

# Guarded: the aliases below still load without Oh My Zsh, so say so once
# instead of erroring at every prompt.
if [ -f "$ZSH/oh-my-zsh.sh" ]; then
    source "$ZSH/oh-my-zsh.sh"
else
    print -u2 "zshrc: Oh My Zsh not found at $ZSH — run install.sh to set it up."
fi
# Guarded like above: name the path tried instead of "no such file or directory".
if [ -f "$ZSH_CONFIG_DIR/zsh-alias" ]; then
    source "$ZSH_CONFIG_DIR/zsh-alias"
else
    print -u2 "zshrc: zsh-alias not found at $ZSH_CONFIG_DIR — aliases and helper functions are off."
fi

# Arrows for zsh-history-substring-search: terminfo covers application mode,
# raw ^[[A/^[[B the rest. Guarded — bindkey takes an undefined widget silently.
zmodload -i zsh/zleparameter 2>/dev/null
if (( ${+widgets[history-substring-search-up]} )); then
    [ -n "$terminfo[kcuu1]" ] && bindkey "$terminfo[kcuu1]" history-substring-search-up
    [ -n "$terminfo[kcud1]" ] && bindkey "$terminfo[kcud1]" history-substring-search-down
    bindkey '^[[A' history-substring-search-up
    bindkey '^[[B' history-substring-search-down
fi

# Composer's global bin — legacy first, so the XDG path wins when both exist.
_prepend_path "$HOME/.composer/vendor/bin"
_prepend_path "$HOME/.config/composer/vendor/bin"
# Homebrew only exists on macOS here — guard so Linux doesn't error.
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

# For autocomplete press Ctrl+Space. Guarded like the arrow keys above.
(( ${+widgets[autosuggest-accept]} )) && bindkey '^ ' autosuggest-accept
