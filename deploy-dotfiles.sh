#!/bin/bash
# changelog
#  2021-04-30  :: Created
#  2021-05-14  :: Improved token generation (now uses globally incrementing #,
#                 raerpb len(tokens)--more robust) and improved parser.
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
declare -g WORKING_DIR

# Array for holding the names of the dynamically generated associative arrays
# with token properties.
declare -a TOKENS
declare -i TOKEN_IDX=0
declare -g LAST_CREATED_TOKEN

# Error tracking:
declare -a ERR_KEY_NOT_FOUND

#───────────────────────────────( import config )───────────────────────────────
declare -g CONFDIR="${PROGDIR}"
declare -g GCONF="${CONFDIR}/config"
# Global config file, in contrast to a locally loaded config file on a per-
# directory basis, specified as `FCONF`.
#
# TODO: This is for testing, so everything can stay in the same directory. Will
#       eventually move over to it's home of ~/.config/hre-utils/deploy-dotfiles
#CONFDIR="${XDG_CONFIG_HOME:-~/.config}/hre-utils/deploy-dotfiles"
#mkdir -p "$CONFDIR"

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

#═══════════════════════════════════╡ LEXER ╞═══════════════════════════════════
function Token {
   # Token types:
   #  OPEN
   #  TEXT
   #  CLOSE

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
#─────────────────────────────────( fill keys )─────────────────────────────────
function is_a_key {
   [[ ! $level -ge 2 ]] && return 1

   # Must be of type "text"
   [[ ! ${token[type]} == 'TEXT' ]] && return 2

   declare -n before_2=${TOKENS[$((idx-1))]}    # <-.
   declare -n before_1=${TOKENS[$((idx-2))]}    # <-+- Two preceding tokens

   declare -n after_1=${TOKENS[$((idx+1))]}     # <-.
   declare -n after_2=${TOKENS[$((idx+2))]}     # <-+- Two subsequent tokens

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

   local value="$(get_value "${token[value]}")"
   if [[ -n $value ]] ; then
      Token 'TEXT' "$value"
   else
      # TODO: `case $missing_key in`
      Token 'TEXT' "KEY_ERROR(${token[value]})"
   fi

   TOKENS=( "${lower[@]}"  "$LAST_CREATED_TOKEN"  "${upper[@]}" )
   ((level-2))
}


function get_value {
   declare -A pretend_dict=(
      [shiftwidth]='SHIFTWIDTH'
      [tabstop]='TABSTOP'
      [triple]='TRIPLE'
      #[this]='THIS'
      [eol]='<END>'
   )

   echo "${pretend_dict[$1]}"
}

#──────────────────────────────( strip comments )───────────────────────────────
function strip_comments {
   echo pass
}

#──────────────────────────────( strip newlines )───────────────────────────────
function strip_newlines {
   echo pass
}

#───────────────────────────────────( parse )───────────────────────────────────
function parse {
   declare -gi level=0 idx=0

   # Tokens may only occur if concluded by: '}', '}'. Stop scanning if there are
   # not at least two subsequent tokens to read.
   while [[ $idx -lt $(( ${#TOKENS[@]} - 1 )) ]] ; do
      token_name="${TOKENS[$idx]}"
      declare -n token="${token_name}"

      # Track current OPEN "indentation" level:
      [[ ${token[type]} == 'OPEN'  ]] && ((level++))
      [[ ${token[type]} == 'CLOSE' ]] && ((level--))

      is_a_key && munch

      ((idx++))
   done

   # [[ $strip_comments =~ ([Tt]rue|[Yy]es) ]] && strip_comments
   # [[ $strip_newlines =~ ([Tt]rue|[Yy]es) ]] && strip_newlines
}


#══════════════════════════════════╡ DEPLOY ╞═══════════════════════════════════
# This is where the actually deployment stuff will go. Largely the same thing as
# the `debug_output` function, but pipes to the destination file after
# potentially backing up the existing file.
#──────────────────────────────────( backup )───────────────────────────────────
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
            local fname="$(basename "${dest}").$(date '+%s')"
            mv "$dest" "${CONFDIR}/backup/${fname}" ;;
   esac
}


#───────────────────────────────────( write )───────────────────────────────────
function deploy {


   case
      slink) cmd='ln -sr' ;;
      hlink) cmd='ln -r'  ;;
      copy)  cmd='cp'     ;;
      icopy) cmd='cp -i'  ;;
      *)     cmd='cp -i'  ;;
   esac
   debug 1 "Deploy method: \`$cmd\`"
}

#═══════════════════════════════════╡ MAIN ╞════════════════════════════════════
#─────────────────────────────────( argparse )──────────────────────────────────
while [[ $# -gt 0 ]] ; do
   case $1 in
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

#──────────────────────────────────( iterdir )──────────────────────────────────
for wdir in $(ls "${CONFDIR}/files") ; do
   WORKING_DIR="${CONFDIR}/files/$wdir"

   if [[ ! -e "${WORKING_DIR}/base" ]] ; then
      debug 2 "No \`base\` file found in ${WORKING_DIR}"
      continue
   fi

   lex ; parse ; debug_output
done
