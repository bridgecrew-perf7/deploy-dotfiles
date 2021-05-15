#!/bin/bash
# changelog
#  2021-04-30  :: Created
#  2021-05-14  :: Improved token generation (now uses globally incrementing #,
#                 raerpb len(tokens)--more robust) and improved parser.

#───────────────────────────────────( notes )───────────────────────────────────
# Should have a CLI option to add a new config file more easily. Will
# automatically create the requisite directory structure, and (if specified),
# `cp` a file in to initially serve as ./files/$name/base, raerpb the
# placeholder. Wonder if we can check if the next CWORD + 1 starts with a '-*',
# then if so assume it's a path to the base file. Example:
# ./deploy-dotfiles --new ~/.vimrc

#──────────────────────────────────( prereqs )──────────────────────────────────
_debug=false

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

# Version requirement: >4
[[ ${BASH_VERSION%%.*} -lt 4 ]] && {
   fname="$(basename ${BASH_SOURCE[0]})"
   echo -e "\n[${fname}] ERROR: Requires Bash version >= 4\n"
   exit 1
}

#═══════════════════════════════════╡ BEGIN ╞═══════════════════════════════════
PROGDIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd )"

# TODO: This is for testing, so everything can stay in the same directory. Will
#       eventually move over to it's home of ~/.config/hre-utils/deploy-dotfiles
#CONFDIR="${XDG_CONFIG_HOME:-~/.config}/hre-utils/deploy-dotfiles"
CONFDIR="${PROGDIR}"
CONFFILE="${CONFDIR}/config.sh"

function debug {
   local lineno=${BASH_LINENO[0]}
   local fname=$(basename "${BASH_SOURCE[0]}")
   local date=$(date '+%Y/%b/%d %T')

   local text color
   if [[ $# -gt 1 ]] ; then
      case $1 in
         debug|DEBUG)   color="${cy}" ;;
         warn|WARN)     color="${yl}" ;;
         crit|CRIT)     color="${brd}" ;;
         *)             color="${wh}" ;;
      esac
      text="$2"
   else
      text="$1"
   fi

   $_debug && {
      printf "[${fname%.*}] $date, ln.%04d\n"  $lineno
      printf " ${color}└── ${text}${rst}\n"
   }
}

#────────────────────────────────( validation )─────────────────────────────────
#if [[ ! -e "${PROGDIR}/files/*/base" ]] ; then
#   echo "Not all files in config/files/ have a 'base'."
#   exit 1
#fi

#readarray -t -d $'\n' FILESDIR < <(ls -1 "${CONFDIR}/files")

# Array for holding the names of the dynamically generated associative arrays
# with token properties.
declare -a TOKENS
declare -i TOKEN_IDX=0
declare LAST_CREATED_TOKEN

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

   debug "Created Token(${t[type]}, ${t[value]})"
}


function debug_tokens {
   for tname in "${TOKENS[@]}" ; do
      declare -n tref=$tname
      local col="${cy}"
      [[ ${tref[type]} == 'OPEN'  ]] && col="${bl}"
      [[ ${tref[type]} == 'CLOSE' ]] && col="${bl}"
      [[ ${tref[type]} == 'KEY'   ]] && col="${bgr}"

      printf "Token(${col}%-9s${rst} '${col}%s${rst}')\n" "${tref[type]}," "${tref[value]}"
   done
}

#═══════════════════════════════════╡ LEXER ╞═══════════════════════════════════

# Scan forwards, filling found characters into a buffer.
function fill {
   delim=$1
   declare -g buffer=''

   while [[ $idx -lt $len ]] ; do
      local c="${chararray[$idx]}"
      local n="${chararray[$((idx+1))]}"

      buffer+="$c"
      [[ "$n" == [{}#] ]] && break

      idx=$((idx+1))
   done

   debug "Buffer filled: [$buffer]"
}


# Load characters into array, so we may iterate over them (and look
# forwards/backwards more easily):
declare -a chararray
while read -r -N1 c ; do
   chararray+=( "$c" )
done < "${CONFDIR}/files/vimrc/base"

len=${#chararray[@]}
declare -i idx=0

while [[ $idx -lt $len ]] ; do
   c="${chararray[$idx]}"

   # Capture comments
   if [[ "$c" == "#" ]] ; then
      fill ; Token 'COMMENT' "$buffer"

   # Start block (or potentially a regular character)
   elif [[ "$c" == '{' ]] ; then
      Token 'OPEN' "$c"

   # End block
   elif [[ "$c" == '}' ]] ; then
      Token 'CLOSE' "$c"

   # The rest of the characters
   else
      # If there are tokens in the stack, get the type of the last token
      # appended to the stack. Must first check if it exists, or subscripting
      # 'tokens' will fail:
      if [[ ${#TOKENS[@]} -gt 0 ]] ; then
         declare -n last_token="${TOKENS[-1]}"
         last_type="${last_token[type]}"
      fi

      if [[ $last_type == 'OPEN' ]] ; then
         fill ; Token 'TEXT' "$buffer"
      fi
   fi

   idx=$(( idx+1 ))
done


#══════════════════════════════════╡ PARSER ╞═══════════════════════════════════
#─────────────────────────────────( fill keys )─────────────────────────────────

# New 'buffer' array to hold the tokens as we iterate over them.
unset buffer ; declare -a buffer
declare -i level=0                  # <- OPEN 'indentation' level
declare -i idx=0                    # <- Current index of tokens[]

function is_a_key {
   # Must be of type "text"
   [[ ! ${token[type]} == 'TEXT' ]] && return 1

   # Must have >=2 tokens left to process, and the current 'OPEN level' must be
   # >=2, else we're not in a {{...}} block:
   [[ ! ${#TOKENS[@]} -ge 2      ]] && return 1
   [[ ! ${level}      -ge 2      ]] && return 1

   declare -n b_2=${buffer[-1]} b_1=${buffer[-2]}
   declare -n t_1=${TOKENS[$((idx+1))]}  t_2=${TOKENS[$((idx+2))]}

   # Must start with 2x '{'...
   [[ ! ${b_2[type]}  == 'OPEN'  ]] && return 1
   [[ ! ${b_1[type]}  == 'OPEN'  ]] && return 1

   # ...and end with  2x '}'
   [[ ! ${t_1[type]}  == 'CLOSE' ]] && return 1
   [[ ! ${t_2[type]}  == 'CLOSE' ]] && return 1

   return 0
}


function munch {
   # Pop last two from buffer[]
   buffer=( "${buffer[@]::$((${#buffer[@]}-2))}" )

   # Slice from 0 -> 2 before the current idx. Should be non-inclusive of both
   # the opening '{{' characters:
   local lower=( "${TOKENS[@]::$((idx-2))}" )

   # Slice from 2 after current idx to end of array. Cuts out the closing '}}':
   local upper=( "${TOKENS[@]:$((idx+2)):$((${#TOKENS[@]}-idx))}" )

   # Create new token based on the dictionary lookup:
   Token 'TEXT' '-----------'

   # Add new value to TOKENS stack & buffer
   TOKENS=( "${lower[@]}"  "$LAST_CREATED_TOKEN"  "${upper[@]}" )
   buffer+=( "$LAST_CREATED_TOKEN" )
}


while [[ $idx -lt ${#TOKENS[@]} ]] ; do
   token_name="${TOKENS[$idx]}"
   declare -n token="${token_name}"

   # Track current indentation level.
   [[ ${token[type]} == 'OPEN'  ]] && ((level++))
   [[ ${token[type]} == 'CLOSE' ]] && ((level--))

   if is_a_key ; then
      munch
   else
      buffer+=( $token_name )
   fi

   ((idx++))
done


#──────────────────────────────( strip comments )───────────────────────────────
#──────────────────────────────( strip newlines )───────────────────────────────

for _v in "${buffer[@]}" ; do
   declare -n v="$_v"
   printf -- "${v[value]}"
done

echo

# TODO;CURRENT;
# Do we actually need the intermediate buffer? Now that we've changed how tokens
# are generated, and they're not based on the length of the TOKENS array, we
# should be able to just modify in-place. Should drastically simplify the checks
# we need to perform as well.
#
# Need to also add a `((level-2))` to the end of `munch()`
