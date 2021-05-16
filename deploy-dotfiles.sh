#!/bin/bash
# changelog
#  2021-04-30  :: Created
#  2021-05-14  :: Improved token generation (now uses globally incrementing #,
#                 raerpb len(tokens)--more robust) and improved parser.
#  2021-05-16  :: Switched all config files to .cfg's, as to parse with mk-conf.
#                 Ability to override global config via per-directory [limited]
#                 heading.
#
#───────────────────────────────────( todo )────────────────────────────────────
# Should have a CLI option to add a new config file more easily. Will
# automatically create the requisite directory structure, and (if specified),
# `cp` a file in to initially serve as ./files/$name/base, raerpb the
# placeholder. Wonder if we can check if the next CWORD + 1 starts with a '-*',
# then if so assume it's a path to the base file. Example:
# ./deploy-dotfiles --new ~/.vimrc

#═══════════════════════════════════╡ BEGIN ╞═══════════════════════════════════
#──────────────────────────────────( prereqs )──────────────────────────────────
# TODO: Some of these features actually need bash 4.2, not just 4.
[[ ${BASH_VERSINFO[0]} -lt 4 ]] && {
   fname="$(basename ${BASH_SOURCE[0]})"
   echo -e "\n[${fname}] ERROR: Requires Bash version >= 4\n"
   exit 1
}

# TODO: source `import.sh`, then use `import` to source the rest
source "$(which mk-conf.sh)"

# TODO: This will be later imported, not explicitly defined. `import mk-colors`
# Colors:
rst=$(tput sgr0)                                   # Reset
bk="$(tput setaf 0)"                               # Black
rd="$(tput setaf 1)"  ;  brd="$(tput bold)${rd}"   # Red     ;  Bright Red
gr="$(tput setaf 2)"  ;  bgr="$(tput bold)${gr}"   # Green   ;  Bright Green
yl="$(tput setaf 3)"  ;  byl="$(tput bold)${yl}"   # Yellow  ;  Bright Yellow
bl="$(tput setaf 4)"  ;  bbl="$(tput bold)${bl}"   # Blue    ;  Bright Blue
mg="$(tput setaf 5)"  ;  bmg="$(tput bold)${bl}"   # Magenta ;  Bright Magenta
cy="$(tput setaf 6)"  ;  bcy="$(tput bold)${cy}"   # Cyan    ;  Bright Cyan
wh="$(tput setaf 7)"  ;  bwh="$(tput bold)${wh}"   # White   ;  Bright White

#(
#   printf '╒═════════════════════════════════════════════╕\n'
#   printf '├──────────────────┤ START ├──────────────────┤\n'
#   printf '│ %s - ' "$(date '+%Y/%b/%d %T')"
#   printf '%-20s │\n' $(printf '%.20s' $(basename "${BASH_SOURCE[0]%.*}"))
#   printf '╘═════════════════════════════════════════════╛\n'
#)

#──────────────────────────────────( global )───────────────────────────────────
PROGDIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd )"

# Directory in which we're currently working, e.g., ./files/vimrc
declare WORKING_DIR

# Array for holding the names of the dynamically generated associative arrays
# with token properties.
declare -a TOKENS
declare -i TOKEN_IDX=0
declare LAST_CREATED_TOKEN

# Error tracking:
declare -a ERRORS_VALIDATION
declare -a ERRORS_RUNTIME

declare -a ERR_KEY_NOT_FOUND
declare -a ERR_LIMITED_CONFIG_NOT_FOUND
declare -a ERR_MISSING_REQUIRED_CONFIG_SECTION


#───────────────────────────────( import config )───────────────────────────────
# TODO: This is for testing, so everything can stay in the same directory. Will
#       eventually move over to it's home of ~/.config/hre-utils/deploy-dotfiles
#CONFDIR="${XDG_CONFIG_HOME:-~/.config}/hre-utils/deploy-dotfiles"
#mkdir -p "$CONFDIR"
declare -g CONFDIR="${PROGDIR}"
declare -g GCONF="${CONFDIR}/config.cfg"

#──────────────────────────────( tmp & debugging )──────────────────────────────
_debug=false

function debug {
   $_debug || return 0

   # Only display debug messages at or above the minimum:
   [[ $1 -lt $__debug_min__ ]] && return 0

   local loglvl lineno=${BASH_LINENO[0]}
   local text color

   case $1 in
      0) color="${cy}"  ; loglvl='DEBUG' ;;
      1) color="${wh}"  ; loglvl='INFO'  ;;
      2) color="${yl}"  ; loglvl='WARN'  ;;
      3) color="${brd}" ; loglvl='CRIT'  ;;
      *) color="${wh}"  ; loglvl='INFO'  ;;
   esac
   text="$2"

   printf '[%-5s] ln.%04d :: %s\n'  "$loglvl"  "$lineno"  "$text"
}


function debug_tokens {
   for tname in "${TOKENS[@]}" ; do
      declare -n tref=$tname
      local col="${cy}"
      [[ ${tref[type]} == 'OPEN'  ]] && col="${bl}"
      [[ ${tref[type]} == 'CLOSE' ]] && col="${bl}"
      [[ ${tref[type]} == 'KEY'   ]] && col="${bgr}"

      # def __repr__(self):
      printf "Token(${col}%-9s${rst} '${col}%s${rst}')\n" "${tref[type]}," "${tref[value]}"
   done
}


function debug_output {
   for _v in "${TOKENS[@]}" ; do
      declare -n v="$_v"
      printf -- "${v[value]}"
   done
}


#───────────────────────────────────( utils )───────────────────────────────────
function load_config {
   #  1. Global config file
   global __activate__

   #  2. Limited config from the working directory
   local LCONF="${WORKING_DIR}/config.cfg"
   if [[ ! -e "$LCONF" ]] ; then
      ERR_LIMITED_CONFIG_NOT_FOUND+=( "${wdir}" )
      return 1
   fi

   .load-conf "$LCONF"
   if ! command -v 'classes' &>/dev/null ; then
      ERR_MISSING_REQUIRED_CONFIG_SECTION+=( "${wdir}[classes]" )
      return 2
   fi

   # If user supplied '[limited]' section, overwrite global:
   command -v 'limited' &>/dev/null && limited __activate__

   return 0
}


#═══════════════════════════════════╡ LEXER ╞═══════════════════════════════════
function Token {
   local type="$1"
   local value="$2"

   # If the first position in the file is a '{', there will be nothing in the
   # buffer that is flushed to a token.
   [[ -z $value ]] && return 0

   # Create name for new token{}, & indexed pointer to it in the tokens[] list:
   tname="Token_${TOKEN_IDX}" ; ((TOKEN_IDX++))
   TOKENS+=( $tname )

   # Create token, and nameref to it so we can assign values based on the
   # dynamic name:
   declare -gA $tname
   declare -n t=$tname
   LAST_CREATED_TOKEN=$tname

   t[type]="$type"
   t[value]="$value"

   debug 0 "Created Token(${t[type]}, ${t[value]})"
}


# Scan forwards, filling found characters into a buffer.
function fill {
   delim=$1
   declare -g buffer=''

   while [[ $idx -lt ${#chararray[@]} ]] ; do
      local c="${chararray[$idx]}"
      local n="${chararray[$((idx+1))]}"

      buffer+="$c"
      [[ "$n" =~ [{}] ]] && break

      idx=$((idx+1))
   done

   debug 0 "Buffer filled: [$buffer]"
}


function lex {
   # Initially load characters into array, so we may iterate over them (and look
   # forwards/backwards more easily):
   declare -a chararray
   while read -r -N1 c ; do
      chararray+=( "$c" )
   done < "${WORKING_DIR}/base"

   # Iterate over chararray, create tokens of either 'OPEN', 'CLOSE', or 'TEXT'
   declare -i idx=0
   while [[ $idx -lt ${#chararray[@]} ]] ; do
      c="${chararray[$idx]}"

      if [[ "$c" == '{' ]] ; then
         Token 'OPEN' "$c"
      elif [[ "$c" == '}' ]] ; then
         Token 'CLOSE' "$c"
      else
         fill ; Token 'TEXT' "$buffer"
      fi

      idx=$(( idx+1 ))
   done
}


#══════════════════════════════════╡ PARSER ╞═══════════════════════════════════
function is_a_key {
   # Must be of type "text"
   [[ ! ${token[type]} == 'TEXT' ]] && return 2

   declare -n before_2=${TOKENS[$((idx-1))]}    # <-.
   declare -n before_1=${TOKENS[$((idx-2))]}    #  <+- Two preceding tokens

   declare -n after_1=${TOKENS[$((idx+1))]}     # <-.
   declare -n after_2=${TOKENS[$((idx+2))]}     #  <+- Two subsequent tokens

   # Must start with 2x '{'...
   [[ ${before_2[type]} != 'OPEN' || ${before_1[type]} != 'OPEN' ]] && {
      debug 0 "$token_name, prior 2 not '{'"
      return 3
   }

   # ...and end with 2x '}'
   [[ ${after_1[type]} != 'CLOSE' || ${after_2[type]} != 'CLOSE' ]] && {
      debug 0 "$token_name, next 2 not '}'"
      return 4
   }

   return 0
}


function munch {
   # Slice from 0 -> 2 before the current idx. Should be non-inclusive of both
   # the opening '{{' characters:
   local lower=( "${TOKENS[@]::$((idx-2))}" )

   # Slice from 3 after current idx to end of array. Starts on the character
   # *after* the closing '}}':
   local upper=( "${TOKENS[@]:$((idx+3)):$((${#TOKENS[@]}-idx))}" )

   # Look up value in options.ini
   local dict="${WORKING_DIR}/options"
   local value=$( classes $class "${token[value]}")

   if [[ -n $value ]] ; then
      Token 'TEXT' "$value"
   else
      # TODO: `case $missing_key in`
      Token 'TEXT' "KEY_ERROR(${token[value]})"
   fi

   TOKENS=( "${lower[@]}"  "$LAST_CREATED_TOKEN"  "${upper[@]}" )
}


function strip_comments {
   echo pass
}


function strip_newlines {
   echo pass
}


function parse {
   declare -gi idx=0

   # Tokens may only occur if concluded by: '}', '}'. Stop scanning if there are
   # not at least two subsequent tokens to read.
   while [[ $idx -lt $(( ${#TOKENS[@]} - 1 )) ]] ; do
      token_name="${TOKENS[$idx]}"
      declare -n token="${token_name}"

      if is_a_key ; then
         munch
      else
         ((idx++))
      fi
   done

   # [[ $strip_comments =~ ([Tt]rue|[Yy]es) ]] && strip_comments
   # [[ $strip_newlines =~ ([Tt]rue|[Yy]es) ]] && strip_newlines
}


#══════════════════════════════════╡ DEPLOY ╞═══════════════════════════════════
function backup_existing {
   local cmd

   case $backup_mode in
      bak)  # In-place backup, re-naming existing file to ${file}.bak
            mv "$dest" "${dest}.bak" ;;

      rm)   # Nukes existing file--AAAH!
            rm -f "$dest" ;;

      irm)  # Interactively nukes existing file--aaah!
            rm -i "$dest" ;;

      *)    # Default option, moves existing file to ./backup/ directory, mildly
            # assuring a unique name:
            local fname="$(basename "${dest}").$(stat --format '%W' ${dest})"
            mv "$dest" "${CONFDIR}/backup/${fname}" ;;
   esac
}


function deploy {
   case $deploy_mode in
      slink) cmd='ln -sr' ;;
      hlink) cmd='ln -r'  ;;
      copy)  cmd='cp'     ;;
      icopy) cmd='cp -i'  ;;
      *)     cmd='cp -i'  ;;
   esac
   debug 1 "Deploy method: \`$cmd\`"
}


#═══════════════════════════════════╡ MAIN ╞════════════════════════════════════
while [[ $# -gt 0 ]] ; do
   case $1 in
      -h|--help)
            echo "Usage doesn't yet exist. [-h] [--debug 0-3]."
            exit 0
            ;;

      --debug)
            shift
            _debug=true
            __debug_min__=$1
            ;;

      *)
            __invalid__+=( $1 )
            shift
            ;;
   esac
done

if [[ -e "${GCONF}" ]] ; then
   .load-conf "${GCONF}"
else
   debug 3 "Couldn't find global configurataion file."
   exit 1
fi

for wdir in $(ls "${CONFDIR}/files") ; do
   # Reset global variables on each run:
   TOKENS=() ; TOKEN_IDX=0 ; LAST_CREATED_TOKEN=
   WORKING_DIR="${CONFDIR}/files/$wdir"

   if [[ ! -e "${WORKING_DIR}/base" ]] ; then
      debug 2 "No \`base\` file found in ${WORKING_DIR}"
      continue
   fi

   load_config ; [[ $? -ne 0 ]] && continue
   # Loads 1) options file, 2) global config, 3) local config

   lex ; parse
   # Reads characters, makes tokens. Read tokens, fills in keys.

   debug_output
   # Reads tokens, makes text.
done


if [[ ${#ERR_LIMITED_CONFIG_NOT_FOUND} -gt 0 ]] ; then
   declare c_list
   for c in "${ERR_LIMITED_CONFIG_NOT_FOUND[@]}" ; do
      c_list+="${c_list:+, }$c"
   done
   errors="Missing config.cfg file: $c_list"
fi ; ERRORS_RUNTIME+=( "$errors" )

if [[ ${#ERRORS_RUNTIME[@]} -gt 0 ]] ; then
   echo "Errors encountered:"
   for idx in "${!ERRORS_RUNTIME[@]}" ; do
      error="${ERRORS_RUNTIME[$idx]}"
      printf '   %02d. %s\n'  "$((idx+1))"  "$error"
   done
fi


# vim:ft=bash:foldmethod=marker:commentstring=#%s
