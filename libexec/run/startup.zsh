emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_session_select_path] )) || source "$SF_ROOT/lib/session.zsh"

# Resume a requested session or delegate creation to shellfish create, and
# report the opened session in REPLY.
sf_run_open_session() {
  local requested=$1 created
  integer override=$2 create_status=0
  shift 2

  if [[ -n $requested ]]; then
    sf_session_select_path "$requested" || { sf_die "$SF_SESSION_ERROR"; return 1; }
    [[ -s $REPLY ]] || {
      sf_die "no session at $REPLY; use --session-out to create one"
      return 1
    }
    (( ! override )) || {
      sf_die 'options that configure a new session cannot be used with an existing one'
      return 2
    }
    return 0
  fi

  created=$("$SF_ENTRY" create "$@") || create_status=$?
  (( ! create_status )) || return $create_status
  [[ -n $created ]] || { sf_die 'create did not return a session path'; return 1; }
  REPLY=$created
}
