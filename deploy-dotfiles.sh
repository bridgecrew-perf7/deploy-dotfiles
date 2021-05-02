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
CONFDIR="${PROGDIR}"
CONFFILE="${CONFDIR}/config.sh"

#────────────────────────────────( validation )─────────────────────────────────
#if [[ ! -e "${PROGDIR}/files/*/base" ]] ; then
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
      if [[ ${#tokens[@]} -gt 0 ]] ; then
         declare -n last_token="${tokens[-1]}"
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
declare -a buffer
declare -i level=0                  # <- Indentation level
declare -i idx=0                    # <- Current index of tokens[]
declare -i len=${#tokens[@]}        # <- len(tokens)

function munch {
   local tname="${tokens[$idx]}"
   declare -n t="${tname}"

   # Last 2 tokens read into the buffer. Don't need to check if they exist, as
   # we only end up here if the $level is 2+. Must have at least two existing
   # tokens.
   declare -n p1="${buffer[-1]}"
   declare -n p2="${buffer[-2]}"

   local _n1="${tokens[$((idx+1))]}"
   local _n2="${tokens[$((idx+2))]}"

   # Next two tokens must exist:
   [[ -z $_n1 || -z $_n2 ]] && return 1

   # Nameref from the token name, to the Token itself
   declare -n n1="$_n1"
   declare -n n2="$_n2"

   # Check both previous tokens are 'OPEN':
   [[ ${p2[type]} != 'OPEN' && ${p1[value]} != 'OPEN' ]] && return 1

   # Check both next tokens are 'CLOSE':
   [[ ${n1[type]} != 'CLOSE' && ${n2[value]} != 'CLOSE' ]] && return 1


   # Going to need to both pop 5 tokens out of the middle of the tokens[] stack,
   declare -a _lower=( "${tokens[@]::$((idx-3))}" )
   declare -a _upper=( "${tokens[@]:$((idx+3)):$(($len-$idx))}" )
   # TODO: Really need to draft out this piece at a small scale. Test to ensure
   #       it's actually doing what I think it does.

   tokens=( "${_lower[@]}" )

   # Create new token as 'TEXT', with the value set to the output of our dict
   # lookup value. For now, for testing (TODO), setting to a static so we can
   # validate it's working:
   #Token 'TEXT' "$(lookup "${t[value]}")"
   Token 'TEXT' "$(lookup "--------")"

   # Concat the upper bound back on after the newly inserted Token.
   for t in "${_upper[@]}" ; do
      tokens+=( "$t" )
   done

   # Declare new length of tokens[]
   len=${#tokens[@]}

   unset buffer[-1]
   unset buffer[-1]

   # Reset idx back down to the position of the newly created Token:
   (( idx-2 ))
   (( level-2 ))

   return 0
}


while [[ $idx -lt $len ]] ; do
   token_name="${tokens[$idx]}"
   declare -n token="${token_name}"

   # Track current indentation level.
   [[ ${token[type]} == 'OPEN'  ]] && ((level++))
   [[ ${token[type]} == 'CLOSE' ]] && ((level--))

   # Tokens can only occur at 2+. No need to look at text <2.
   if [[ $level -ge 2 || ${token[type]} == 'TEXT' ]] ; then
      munch && continue
   fi

   buffer+=( $token_name )
   ((idx++))
done


#──────────────────────────────( strip comments )───────────────────────────────
#──────────────────────────────( strip newlines )───────────────────────────────
