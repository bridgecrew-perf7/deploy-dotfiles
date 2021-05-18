#!/bin/bash
# changelog
#  2021-04-30  :: Created
#  2021-05-14  :: Improved token generation (now uses globally incrementing #,
#                 raerpb len(tokens)--more robust) and improved parser.
#  2021-05-16  :: Switched all config files to .cfg's, as to parse with mk-conf.
#                 Ability to override global config via per-directory [base]
#                 heading.
#
#───────────────────────────────────( todo )────────────────────────────────────
# 1. [ ] CLI options:
#        1. [X] "--new" Automatically create the requisite directory structure
#        2. [ ] "--find" Echo path to the 'base` of a specified search term
#        3. [ ] "--clean" Remove >3 files from each dir in ./dist. Pretty simple
#                         rm $(/usr/bin/ls -1 ./dist/*/* | sort | tail -n +3)
#
# 2. [ ] Reporting. Compile information during the run into a final report. Use
#        a trap to ensure the report is actually written on exits or failure.
#        Report should contain: 1) exit status, 2) run summary, 3) operations
#        performed, 4) errors encountered.
#
# 3. [ ] Diff previously generated files. If there's no differences, no need to
#        compile them again. Best way to do this might be a dotfile within each
#        ./dist/$WDIR with a md5sum of the base file, and the filename it's
#        created. Before running, we md5sum the 'base' file, grep the list to
#        see if there's an existing entry.
#
# 4. [ ] Easier option for files that don't have any processing required. If it
#        it something that's as simple as a 'cp' with no variables.

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

# Used in logging, and temp filename generation in ./dist/. Allows us to pair
# a section in a report/logfile with a particular generated filed.
declare RUNID="$(date '+%s')"

# Directory in which we're currently working, e.g., ./files/vimrc
declare WORKING_DIR

# Array for holding the names of the dynamically generated associative arrays
# with token properties.
declare -a TOKENS
declare -i TOKEN_IDX=0
declare LAST_CREATED_TOKEN

# Error tracking:
declare -a ERRORS_IN_VALIDATION
declare -a ERRORS_AT_RUNTIME

declare -a ERR_KEY_NOT_FOUND
declare -a ERR_BASE_CONFIG_NOT_FOUND
declare -a ERR_MISSING_REQUIRED_CONFIG_KEY
declare -a ERR_MISSING_REQUIRED_CONFIG_SECTION


#───────────────────────────────( import config )───────────────────────────────
# TODO: This is for testing, so everything can stay in the same directory. Will
#       eventually move over to it's home of ~/.config/hre-utils/deploy-dotfiles
#CONFDIR="${XDG_CONFIG_HOME:-~/.config}/hre-utils/deploy-dotfiles"
#mkdir -p "$CONFDIR"
declare -g CONFDIR="${PROGDIR}"
declare -g GCONF="${CONFDIR}/config.cfg"

#──────────────────────────────( tmp & debugging )──────────────────────────────
function debug {
   $__debug__ || return 0

   local debug_min debug_max message_level=$1
   read -r debug_min debug_max __ <<< ${__debug_level__//,/ }

   # Only display debug messages that are within the specified range
   [[ $message_level -lt $debug_min ]] && return 0
   [[ $message_level -gt $debug_max ]] && return 0

   local loglvl lineno=${BASH_LINENO[0]}
   local text color

   case $message_level in
     -1) color="${bk}"  ; loglvl='NOISE' ;;
      0) color="${cy}"  ; loglvl='DEBUG' ;;
      1) color="${wh}"  ; loglvl='INFO'  ;;
      2) color="${yl}"  ; loglvl='WARN'  ;;
      3) color="${brd}" ; loglvl='CRIT'  ;;

      *) color="${wh}"  ; loglvl='INFO'  ;;
   esac
   text="$2"

   printf "${color}[%-5s] ln.%04d :: %s${rst}\n"  "$loglvl"  "$lineno"  "$text"
}


function debug_tokens {
   for tname in "${TOKENS[@]}" ; do
      declare -n tref=$tname
      local col="${cy}"
      [[ ${tref[type]} == 'NEWLINE' ]] && col="${bk}"
      [[ ${tref[type]} == 'OPEN'    ]] && col="${bl}"
      [[ ${tref[type]} == 'CLOSE'   ]] && col="${bl}"
      [[ ${tref[type]} == 'TEXT'    ]] && col="${bgr}"

      # def __repr__(self):
      printf "Token(${col}%-9s${rst} ${col}%s${rst})\n" "${tref[type]}," "${tref[value]@Q}"
   done
}


function debug_output {
   for tname in "${TOKENS[@]}" ; do
      declare -n token="$tname"
      printf -- "${token[value]}"
   done
}


#───────────────────────────────────( utils )───────────────────────────────────
function usage {
cat <<EOF
USAGE: ./$(basename "${BASH_SOURCE[@]}") [OPTION | COMMAND]

Options:
   -h | --help              show this message and exit
   -b | --build-only        compile output to 'dist/', do not deploy to
   -d | --debug LOW[,HIGH]  set debug level range

Commands:
   -n | --new NAME PATH     creates new entry for NAME, copying PATH as a 'base'
EOF

exit $1
}


function load_config {
   # Unset prior [base] if exists:
   [[ $(command -v base &>/dev/null) ]] && base --rm

   # Initially load global configurations, potentially overwritten by [base]:
   global --activate

   # Must contain a config file for each base dotfile
   local LCONF="${WORKING_DIR}/config.cfg"
   if [[ ! -e "$LCONF" ]] ; then
      ERR_BASE_CONFIG_NOT_FOUND+=( "${WDIR}" )
      debug 2 "Missing config file for ${WDIR}."
      return 1
   fi

   # Loads per-directory configuration
   .load-conf "$LCONF"

   # Requires sections [base] & [classes]
   declare -a required_sections=( base classes )
   for sect in "${required_sections[@]}" ; do
      if ! command -v "$sect" &>/dev/null ; then
         ERR_MISSING_REQUIRED_CONFIG_SECTION+=( "${WDIR}.$sect" )
         debug 2 "Missing config section: ${WDIR}.$sect"
      fi
   done
   [[ ${#ERR_MISSING_REQUIRED_CONFIG_SECTION[@]} -gt 0 ]] && return 2

   # Requires specified keys in [base]:
   declare -a required_base_keys=( name destination )
   for key in "${required_base_keys[@]}" ; do
      if [[ ! $(base $key) ]] ; then
         ERR_MISSING_REQUIRED_CONFIG_KEY+=( "${WDIR}.base.$key" )
         debug 2 "Missing config section: ${WDIR}.base.$key"
      fi
   done
   [[ ${#ERR_MISSING_REQUIRED_CONFIG_KEY[@]} -gt 0 ]] && return 3

   # Sets all variables from [base] section, overriding any previously set
   # values from the [global] section:
   base --activate
   return 0
}


function create_base_config {
   # Sets directory name after stripping the suffix and leading '.'
   local cname=$1 ; [[ $cname =~ ^\.?(.*) ]] ; cname="${BASH_REMATCH[1]%.*}"
   local starting_file="$2"

   local cdir="${PROGDIR}/files/${cname}"
   mkdir -p "$cdir"
   debug 1 "Created new directory at $cdir" 

   gen_base_config > "${cdir}/config.cfg"

   [[ -n "$starting_file" ]] && cp "$starting_file" "${cdir}/base"
   debug 1 "Copying '$starting_file' to '${cdir}/base'"
}


function gen_base_config {
cat <<EOF
# Required headings: [base], [classes]
# Required keys: base.name, base.destination

[base]
# Specifies the destination directory & file name:
name=$cname
destination=

# Can additionally override [global] config options on a per-directory basis.
# Example, don't strip comment characters in only this base file:
#  strip_comments=false

[classes]
# key:value pairs are defined here, nested under each named subsection. Example,
# to define a class for servers:
[[server]]
key=value
EOF
}

#═══════════════════════════════════╡ LEXER ╞═══════════════════════════════════
function Token {
   local type="$1" value="$2"

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

   debug -1 "Created $tname(${t[type]}, ${t[value]@Q})"
}


# Scan forwards, filling found characters into a buffer.
function fill {
   delim=$1
   declare -g buffer=''

   while [[ $idx -lt ${#chararray[@]} ]] ; do
      local c="${chararray[$idx]}"
      local n="${chararray[$((idx+1))]}"

      buffer+="$c"
      [[ "$n" =~ [{}$'\n'] ]] && break

      idx=$((idx+1))
   done

   #debug -1 "Buffer filled: [$buffer]"
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
      elif [[ "$c" == $'\n' ]] ; then
         Token 'NEWLINE' "$c"
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
      return 3
   }

   # ...and end with 2x '}'
   [[ ${after_1[type]} != 'CLOSE' || ${after_2[type]} != 'CLOSE' ]] && {
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
   cchar=${comment_character:-$'#'}

   for tname in "${TOKENS[@]}" ; do
      declare -n token=$tname
      if [[ ${token[type]} == 'TEXT' ]] ; then
         token[value]="${token[value]%%${cchar}*}"
      fi
   done
}


function strip_newlines {
   # If you have the following tokens...
   #  Token(TEXT, 'set')
   #  Token(KEY,  '{{key}}')
   # ...the 'set' will receive a trailing newline, even though it did not have
   # one originally. Need to have a way to only strip _intermediate_ newlines.
   # But then what if we have a standalone newline? Ugh, turns out this is more
   # difficult than I thought.
   #
   # Maybe this can be part of post processing step? Once all character-by-
   # character substitution is done, compile everything back to a straight up
   # text string in a buffer. Then operate linewise via a while read.
   #
   # OOOOH. Or do we make a new token for newlines. Then if we hit more than one
   # in a row, we blast them until the following token isn't a newline. I like
   # this. Going to be a bit of a lower priority, after deployment is 'done'.

   declare -i idx=0

   while [[ $idx -lt $(( ${#TOKENS[@]} - 1 )) ]] ; do
      declare tname=${TOKENS[$idx]}

      declare -n token=${tname}
      declare -n next=${TOKENS[$idx+1]}

      [[ "${token[type]}" == 'NEWLINE' ]] && \
      [[ "${next[type]}" == 'NEWLINE' ]] && {
         unset $tname ; unset TOKENS[$idx]
         # Don't actually think it's necessary to unset the token array itself,
         # can simply pop it from TOKENS. Just 'cause though.
      }

      ((idx++))
   done
}


function parse {
   declare -gi idx=0

   # Tokens may only occur if concluded by: '}', '}'. Stop scanning if there are
   # not at least two subsequent tokens to read.
   while [[ $idx -lt $(( ${#TOKENS[@]} - 2 )) ]] ; do
      token_name="${TOKENS[$idx]}"
      declare -n token="${token_name}"

      if is_a_key ; then
         munch
      else
         ((idx++))
      fi
   done

   [[ $strip_comments =~ ([Tt]rue|[Yy]es) ]] && strip_comments
   [[ $strip_newlines =~ ([Tt]rue|[Yy]es) ]] && strip_newlines
}


#══════════════════════════════════╡ DEPLOY ╞═══════════════════════════════════
function backup_existing {
   local cmd dest="$1"

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
      slink)  cmd='ln -sr' ;;  # Symlink
      hlink)  cmd='ln -r'  ;;  # Hard link
      copy)   cmd='cp'     ;;  # Copy
      icopy)  cmd='cp -i'  ;;  # Copy, interactive (default)
      *)      cmd='cp -i'  ;;
   esac
   debug 1 "Deploy method: \`$cmd\`"

   local dist="${PROGDIR}/dist/${WDIR}/$RUNID"
   mkdir -p "$(dirname "$dist")"

   ( for tname in "${TOKENS[@]}" ; do
        declare -n token=$tname
        printf -- '%s' "${token[value]}"
     done
   ) > "$dist"

   $__build_only__ && return 0

   local _dest="$(base destination)"
   local _dest="${_dest%/}"
   [[ "$_dest" =~ ^~ ]] && _dest="${_dest/$'~'/${HOME}}"

   local destination="${_dest}/$(base name)"
   [[ -e "$destination" ]] && backup_existing "$destination" 

   #"$cmd" "$dist" "$destination"
   echo "DEBUG: $cmd '$dist' '$destination'"
}


#═══════════════════════════════════╡ MAIN ╞════════════════════════════════════
#─────────────────────────────────( argparse )──────────────────────────────────
# Defaults:
__debug__=false
__build_only__=false

while [[ $# -gt 0 ]] ; do
   case $1 in
      -h|--help)
            usage 0
            ;;

      -n|--new)
            shift
            create_base_config "$1" "$2"
            exit 0
            ;;

      -n|--build-only)
            shift
            __build_only__=true
            ;;

      -d|--debug)
            shift
            __debug__=true
            __debug_level__=$1
            ;;

      *)
            __invalid__+=( $1 )
            shift
            ;;
   esac
done

#─────────────────────────────────( validate )──────────────────────────────────
if [[ -e "${GCONF}" ]] ; then
   .load-conf "${GCONF}"
else
   debug 3 "Couldn't find global configurataion file."
   exit 1
fi

#───────────────────────────────────( main )────────────────────────────────────
for WDIR in $(ls "${CONFDIR}/files") ; do
   # Reset global variables on each run:
   TOKENS=() ; TOKEN_IDX=0 ; LAST_CREATED_TOKEN=
   WORKING_DIR="${CONFDIR}/files/$WDIR"

   if [[ ! -e "${WORKING_DIR}/base" ]] ; then
      debug 2 "No \`base\` file found in ${WORKING_DIR}"
      continue
   fi

   load_config ; [[ $? -ne 0 ]] && continue
   # Loads 1) options file, 2) global config, 3) local config

   lex ; parse
   # Reads characters, makes tokens. Read tokens, fills in keys

   debug_output
   # Reads tokens, prints compilation

   #deploy
   # Reads tokens, makes files
done


# Debugging and basic error reporting
#
#if [[ ${#ERR_BASE_CONFIG_NOT_FOUND} -gt 0 ]] ; then
#   declare c_list
#   for c in "${ERR_BASE_CONFIG_NOT_FOUND[@]}" ; do
#      c_list+="${c_list:+, }$c"
#   done
#   errors="Missing config.cfg file: $c_list"
#fi ; ERRORS_AT_RUNTIME+=( "$errors" )
#
#if [[ ${#ERRORS_AT_RUNTIME[@]} -gt 0 ]] ; then
#   echo "Errors encountered:"
#   for idx in "${!ERRORS_AT_RUNTIME[@]}" ; do
#      error="${ERRORS_AT_RUNTIME[$idx]}"
#      printf '   %02d. %s\n'  "$((idx+1))"  "$error"
#   done
#fi


# vim:ft=bash:foldmethod=marker:commentstring=#%s
