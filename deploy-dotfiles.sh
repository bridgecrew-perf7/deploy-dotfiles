#!/bin/bash
# changelog
#  2021-04-30  :: Created

#───────────────────────────────────( notes )───────────────────────────────────
# Should have a CLI option to add a new config file more easily. Will
# automatically create the requisite directory structure, and (if specified),
# `cp` a file in to initially serve as ./files/$name/base, raerpb the
# placeholder. Wonder if we can check if the next CWORD + 1 starts with a '-*',
# then if so assume it's a path to the base file. Example:
# ./deploy-dotfiles --new ~/.vimrc
#
# This should definitely be multi-pass. Several validation passes of the
# directory structure entirely. Then passes over each file within the that
# file's path: ./config/.../vimrc/*
#
# Ugh, do we actually want to make this a lexer, just to scan for our {{...}}
# keys? Could certainly just read line by line, then look up the value, fill it
# in, and write the line back. Maybe I'll try a very basic lexer first.

#──────────────────────────────────( prereqs )──────────────────────────────────
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
CONFDIR="${PROGDIR}/config/hre-utils/deploy-dotfiles"

#────────────────────────────────( validation )─────────────────────────────────
#if [[ ! -e "${CONFDIR}/files/*/base" ]] ; then
#   echo "Not all files in config/files/ have a 'base'."
#   exit 1
#fi

#readarray -t -d $'\n' FILESDIR < <(ls -1 "${CONFDIR}/files")

# Array for holding the names of the dynamically generated associative arrays
# with token properties.
declare -a tokens

function Token {
   # Token types:
   #  OPEN
   #  KEY
   #  CLOSE
   #  USERTEXT

   local type="$1"
   local value="$2"

   # If the first position in the file is a '{', there will be nothing in the
   # buffer that is flushed to a token.
   [[ -z $value ]] && return 0

   # Create name for new token{}, & indexed pointer to it in the tokens[] list:
   tnum=${#tokens[@]}
   tname="Token_${tnum}"
   tokens+=( $tname )

   # Create token, and nameref to it so we can assign values based on the
   # dynamic name:
   declare -gA $tname
   declare -n t=$tname

   t[type]="$type"
   t[value]="$value"
}


function debug_tokens {
   for tname in "${tokens[@]}" ; do
      declare -n tref=$tname
      local col="${cy}"
      [[ ${tref[type]} == 'OPEN'  ]] && col="${bl}"
      [[ ${tref[type]} == 'CLOSE' ]] && col="${bl}"
      [[ ${tref[type]} == 'KEY'   ]] && col="${bgr}"

      printf "Token(${col}%-9s${rst} '${col}%s${rst}')\n" "${tref[type]}," "${tref[value]}"
   done
}

#═══════════════════════════════════╡ LEXER ╞═══════════════════════════════════
#───────────────────────────────( while read v1 )───────────────────────────────
#cur_type=''
#buffer=''
#
#while read -r -N1 c ; do
#   if [[ $c == '{' ]] ; then
#      # Flush current buffer to token:
#      Token $cur_type "$buffer"
#      cur_type='OPEN'
#      buffer="$c"
#   elif [[ $c == '}' ]] ; then
#      Token $cur_type "$buffer"
#      cur_type='CLOSE'
#      buffer="$c"
#   else
#      if [[ $cur_type == 'OPEN' ]] ; then
#         cur_type='KEY'
#         buffer=''
#      elif [[ $cur_type == 'CLOSE' ]] ; then
#         cur_type='USERTEXT'
#         buffer=''
#      elif [[ $cur_type == 'KEY' ]] ; then
#         cur_type='KEY'
#      else
#         cur_type='USERTEXT'
#      fi
#      buffer+="$c"
#   fi
#done < "${CONFDIR}/files/vimrc/base"
#
## Final buffer flush:
#Token $cur_type "$buffer"
#
## Did it work??
#debug_tokens
#───────────────────────────────────( array )───────────────────────────────────
# Scan forwards, filling found characters into a buffer.
function fill_to {
   delim=$1
   declare -g buffer=''

   while [[ $idx -lt $len ]] ; do
      local c="${chararray[$idx]}"
      local n="${chararray[$((idx+1))]}"

      buffer+="$c"
      [[ "$n" == "$delim" ]] && break

      idx=$((idx+1))
   done
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
   if [[ "$c" == "$comment_start" ]] ; then
      fill_to "${comment_end:-$'\n'}"
      Token 'COMMENT' "$buffer"

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
      if [[ ${#tokens[@]} -gt 0 ]] ; then
         declare -n last_token="${tokens[-1]}"
         last_type="${last_token[type]}"
      fi

      if [[ $last_type == 'OPEN' ]] ; then
         fill_to '}'
         Token 'KEY' "$buffer"
      else
         fill_to '{'
         Token 'USERTEXT' "$buffer"
      fi
   fi

   idx=$(( idx+1 ))
done

# Buffer should be empty, if it's not at this point we have an unterminated
# expression left hanging.
#[[ -n $buffer ]] && {
#   echo "UH OH, BUFFER CONTENTS NOT EMPTY."
#   echo "FUCK YOU"
#   echo "Contents: ($buffer)"
#   exit 1
#}

debug_tokens

#══════════════════════════════════╡ PARSER ╞═══════════════════════════════════
