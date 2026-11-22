zmodload zsh/datetime
source "$SHELLFISH_SHARE_DIR/lib/capped.zsh" || return 1

sf_git_identity() {
  local deadline=$1 branch hash
  branch=$(sf_capped "$deadline" git symbolic-ref --quiet --short HEAD 2>/dev/null)
  case $? in
    0) print -r -- "branch:$branch" ;;
    1)
      hash=$(sf_capped "$deadline" git rev-parse --verify HEAD 2>/dev/null) || return 1
      print -r -- "commit:$hash"
      ;;
    *) return 1 ;;
  esac
}

sf_git_save_identity() {
  jq -cn --arg identity "$1" '{state_update:[{name:"git/identity",value:$identity}]}' >&3
}
