# If not running interactively, don't do anything
[[ $- != *i* ]] && return
alias ls='ls --color=auto'
alias grep='grep --color=auto'
# 🌸 Vaporwave Prompt
PS1='\[\e[38;5;212m\][\u@\h \W]\$\[\e[0m\] '
export PATH="$HOME/.local/bin:$PATH"
