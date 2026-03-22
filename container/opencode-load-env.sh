#!/usr/bin/env bash

restore_shell_option() {
  local option_name="$1"
  local was_enabled="$2"

  if [ "$was_enabled" = "1" ]; then
    set -o "$option_name"
  else
    set +o "$option_name"
  fi
}

load_opencode_env() {
  local env_dir env_file was_errexit was_nounset should_skip

  should_skip=0

  if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${OPENCODE_ENV_LOADED:-}" = "1" ]; then
    should_skip=1
  fi

  if [ "$should_skip" = "1" ]; then
    return 0
  fi

  export OPENCODE_ENV_LOADED=1
  env_dir="${HOME}/.config/opencode/env.d"

  if [ ! -d "$env_dir" ]; then
    return 0
  fi

  case $- in
    *e*) was_errexit=1 ;;
    *) was_errexit=0 ;;
  esac

  case $- in
    *u*) was_nounset=1 ;;
    *) was_nounset=0 ;;
  esac

  set +e +u
  shopt -s nullglob
  for env_file in "$env_dir"/*.sh; do
    if [ -r "$env_file" ]; then
      . "$env_file"
    fi
  done
  shopt -u nullglob
  restore_shell_option errexit "$was_errexit"
  restore_shell_option nounset "$was_nounset"
}

load_opencode_env

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -gt 0 ]; then
  exec "$@"
fi
