#!/bin/bash
# changelog
#  2021-04-30  :: Created
#  2021-05-14  :: Improved token generation (now uses globally incrementing #,
#                 raerpb len(tokens)--more robust) and improved parser.
#  2021-05-16  :: Switched all config files to .cfg's, as to parse with mk-conf.
#                 Ability to override global config via per-directory [base]
#                 heading.
#  2021-05-18  :: Standardized variable names, added 'base' diffing so we don't
#                 re-run on already compiled files.
#

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

# Directory in which we're currently working. Example, for a 'vimrc'
#  WORKING_NAME=vimrc
#  WORKING_DIR=$DATADIR/files/vimrc
#  DIST_DIR=$DATADIR/dist/vimrc
declare WORKING_NAME WORKING_DIR DIST_DIR

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
#DATADIR="${XDG_DATA_HOME:-${HOME}/.local/share}/hre-utils/deploy-dotfiles"
#mkdir -p "$DATADIR"
declare -g DATADIR="${PROGDIR}"
declare -g GLOBAL_CONF="${DATADIR}/config.cfg"

#──────────────────────────────( tmp & debugging )──────────────────────────────
function debug {
   $__debug__ || return 0

   local debug_min debug_max message_level=$1
   read -r debug_min debug_max __ <<< ${__debug_level__//,/ }

   # Only display debug messages that are within the specified range
   [[ $message_level -lt $debug_min ]] && return 0
   [[ $message_level -gt ${debug_max:-3} ]] && return 0

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
      declare -n token=$tname
      local col="${cy}"
      [[ ${token[type]} == 'NEWLINE' ]] && col="${bk}"
      [[ ${token[type]} == 'OPEN'    ]] && col="${bl}"
      [[ ${token[type]} == 'CLOSE'   ]] && col="${bl}"
      [[ ${token[type]} == 'TEXT'    ]] && col="${bgr}"

      # def __repr__(self):
      printf "Token(${col}%-9s${rst} ${col}%s${rst})\n" "${token[type]}," "${token[value]@Q}"
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
USAGE: ./$(basename "${BASH_SOURCE[@]}") [OPTION] [COMMAND]

Options:
   -h | --help              show this message and exit
   -b | --build-only        compile output to 'dist/', do not deploy to
   -d | --debug LOW[,HIGH]  set debug level range

Commands:
   -c | --clean NUMBER      purges ./dist, maintaining NUMBER entries
   -n | --new PATH          inits new base directory, copying PATH if exists
EOF

exit $1
}


function load_config {
   # Unset prior [base] if exists:
   [[ $(command -v base &>/dev/null) ]] && base --rm

   # Initially load global configurations, potentially overwritten by
   # previous [base] activation:
   global --activate

   # Must contain a config file for each base dotfile
   local local_conf="${WORKING_DIR}/config.cfg"
   if [[ ! -e "$local_conf" ]] ; then
      ERR_BASE_CONFIG_NOT_FOUND+=( "${WORKING_NAME}" )
      debug 2 "Missing config file for ${WORKING_NAME}."
      return 1
   fi

   # Loads per-directory configuration
   .load-conf "$local_conf"

   # Requires sections [base] & [classes]
   declare -a required_sections=( base classes )
   for sect in "${required_sections[@]}" ; do
      if ! command -v "$sect" &>/dev/null ; then
         ERR_MISSING_REQUIRED_CONFIG_SECTION+=( "${WORKING_NAME}.$sect" )
         debug 2 "Missing config section: ${WORKING_NAME}.$sect"
      fi
   done
   [[ ${#ERR_MISSING_REQUIRED_CONFIG_SECTION[@]} -gt 0 ]] && return 2

   # Requires specified keys in [base]:
   declare -a required_base_keys=( name destination )
   for key in "${required_base_keys[@]}" ; do
      if [[ ! $(base $key) ]] ; then
         ERR_MISSING_REQUIRED_CONFIG_KEY+=( "${WORKING_NAME}.base.$key" )
         debug 2 "Missing config section: ${WORKING_NAME}.base.$key"
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
   local destination="$(dirname "$__full_path__")"
   local name="$(basename "$__full_path__")"
   local wdir_name="${name%.*}"
   [[ "$wdir_name" =~ ^\.?(.*) ]] && wdir_name="${BASH_REMATCH[1]}"

   # Create new working directory:
   local new_wdir="${DATADIR}/files/${wdir_name}"
   mkdir -pv "$new_wdir"

   # Paths to new base & config files:
   local new_basefile="${new_wdir}/base"
   local new_conffile="${new_wdir}/config.cfg"

   cat <<EOF > "${new_conffile}"
# Required headings: [base], [classes]
# Required keys: base.name, base.destination

[base]
# Specifies the destination directory & file name:
name=$name
destination=$destination

# Can additionally override [global] config options on a per-directory basis.
# Example, don't strip comment characters in only this base file:
#  strip_comments=false

[classes]
# key:value pairs are defined here, nested under each named subsection. Example,
# to define a class for servers:
[[server]]
key=value
EOF

   if [[ -e "$__full_path__" ]] ; then
      cp -iv "$__full_path__" "$new_basefile"
   fi

   touch "$new_basefile"
}


function file_unmodified {
   local hash name
   local check="$(md5sum "${WORKING_DIR}/base" | awk '{print $1}')"
   local database="${DIST_DIR}/.db" 
   
   [[ ! -e "$database" ]] && return 1

   read -r hash name < <(grep "$check" "$database")
   [[ -z "$name" ]] && return 1

   debug 1 "${WORKING_NAME} already processed as ${WORKING_NAME}/$name"
   #echo "$name"
   return 0
}


function clean_dist {
   declare -i num=$1

   for wdir in $(ls -d "${DATADIR}/dist/"*) ; do
      for file in $(ls "${wdir}" | sort | tail -n +${num}) ; do
         # 1. Remove file from directory
         debug 1 "$(rm -v "${wdir}/${file}")"

         # 2. Remove entry from directory's database file
         local db="${wdir}/.db"
         [[ -e "$db" ]] && sed -i "/${file}/d" "$db"
      done
   done
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
   declare -g BUFFER=''

   while [[ $idx -lt ${#CHARARRAY[@]} ]] ; do
      local c="${CHARARRAY[$idx]}"
      local n="${CHARARRAY[$((idx+1))]}"

      BUFFER+="$c"
      [[ "$n" =~ [{}$'\n'] ]] && break

      idx=$((idx+1))
   done
}


function lex {
   # Initially load characters into array, so we may iterate over them (and look
   # forwards/backwards more easily):
   declare -a CHARARRAY
   while read -r -N1 c ; do
      CHARARRAY+=( "$c" )
   done < "${WORKING_DIR}/base"

   # Iterate over CHARARRAY, create tokens of either 'OPEN', 'CLOSE', or 'TEXT'
   declare -i idx=0
   while [[ $idx -lt ${#CHARARRAY[@]} ]] ; do
      local c="${CHARARRAY[$idx]}"

      if [[ "$c" == '{' ]] ; then
         Token 'OPEN' "$c"
      elif [[ "$c" == '}' ]] ; then
         Token 'CLOSE' "$c"
      elif [[ "$c" == $'\n' ]] ; then
         Token 'NEWLINE' "$c"
      else
         fill ; Token 'TEXT' "$BUFFER"
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
      case $missing_key in
         quiet)   # do not warn, leave text as is
                  Token 'TEXT' "${token[value]}"
                  ;;
                  
         warn)    # warn user, leave text as is
                  debug 2 "Token ${WORKING_NAME}.${class}.${token[value]} not found in config"
                  Token 'TEXT' "${token[value]}"
                  ;;

         rm)      # warn & replace with empty string
                  debug 2 "Token ${WORKING_NAME}.${class}.${token[value]} not found in config"
                  Token 'TEXT' ''
                  ;;

         repl)    # warn * replace with KEY_ERROR($key)
                  debug 2 "Token ${WORKING_NAME}.${class}.${token[value]} not found in config"
                  Token 'TEXT' "KEY_ERROR(${token[value]})"
                  ;;

         *)       # Default action: 'repl'
                  debug 2 "Token ${WORKING_NAME}.${class}.${token[value]} not found in config"
                  Token 'TEXT' "KEY_ERROR(${token[value]})"
                  ;;
      esac
   fi

   TOKENS=( "${lower[@]}"  "$LAST_CREATED_TOKEN"  "${upper[@]}" )
}


function strip_comments {
   local cchar=${comment_character:-$'#'}

   for tname in "${TOKENS[@]}" ; do
      declare -n token=$tname
      if [[ ${token[type]} == 'TEXT' ]] ; then
         token[value]="${token[value]%%${cchar}*}"
      fi
   done
}


function strip_newlines {
   # There can be problems when stripping newlines after keys have been filled
   # in. May need to tokenize the inserted text prior to stripping newlines and
   # comments.

   declare -i idx=0

   while [[ $idx -lt $(( ${#TOKENS[@]} - 1 )) ]] ; do
      declare tname=${TOKENS[$idx]}

      declare -n token=${tname}
      declare -n next=${TOKENS[$idx+1]}

      [[ "${token[type]}" == 'NEWLINE' ]] && \
      [[ "${next[type]}" == 'NEWLINE' ]] && {
         unset $tname ; unset TOKENS[$idx]
         # Don't actually think it's necessary to unset the token dict itself,
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
      local tname="${TOKENS[$idx]}"
      declare -n token="${tname}"

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
function build {
   local dist_file="$1"

   case $deploy_mode in
      slink)  cmd='ln -sr' ;;  # Symlink
      hlink)  cmd='ln -r'  ;;  # Hard link
      copy)   cmd='cp'     ;;  # Copy
      icopy)  cmd='cp -i'  ;;  # Copy, interactive (default)
      *)      debug 2 "deploy_mode invalid, defaulting to 'icopy'"
              declare -g deploy_mode='icopy'
              deploy ;;
   esac

   mkdir -p "$(dirname "$dist_file")"

   ( for tname in "${TOKENS[@]}" ; do
        declare -n token=$tname
        printf -- '%s' "${token[value]}"
     done
   ) > "$dist_file"

   # Saves hash of the base file, with pointer to the compiled file. Allows us
   # to check if the file is unmodified since the last run.
   local db_entry="$(md5sum "${WORKING_DIR}/base" | awk '{print $1}') ${RUNID}" 
   echo "$db_entry" >> "${DIST_DIR}/.db"
}


function backup_existing {
   local cmd dest="$1"
   debug 1 "Target file ${dest} exists. Backing up."

   case $backup_mode in
      rm)   # Nukes existing file--AAAH!
            rm -f "$dest" ;;

      irm)  # Interactively nukes existing file--aaah!
            rm -i "$dest" ;;

      bak)  # In-place backup, re-naming existing file to $file.bak
            mv "$dest" "${dest}.bak" ;;

      dir)  # Default option, moves existing file to ./backup/ directory, sets
            # name to the last modification time of the file.
            local fname="$(basename "${dest}").$(stat --format '%W' ${dest})"
            mv "$dest" "${DATADIR}/backup/${fname}" ;;

      *)    debug 2 "backup_mode invalid, defaulting to 'dir', re-running backup"
            declare -g backup_mode='dir'
            backup_existing "$dest" ;;
   esac
}


function deploy {
   local dist_file="${DIST_DIR}/$RUNID"

   build "$dist_file"
   $__build_only__ && return 0

   local _dest="$(base destination)"
   local _dest="${_dest%/}"
   [[ "$_dest" =~ ^~ ]] && _dest="${_dest/$'~'/${HOME}}"

   local destination="${_dest}/$(base name)"
   [[ -e "$destination" ]] && backup_existing "$destination" 

   debug 1 "Deploying '$dist_file' to '$destination' via cmd '$cmd'"
   $cmd "$dist_file" "$destination"
}

#═══════════════════════════════════╡ MAIN ╞════════════════════════════════════
#─────────────────────────────────( argparse )──────────────────────────────────
# Defaults:
__debug__=false
__build_only__=false

# TODO: Drop in @hre-utils/argparse later. May not actually need the
#       configurable argument parsing, just the drop-in skeleton.
while [[ $# -gt 0 ]] ; do
   case $1 in
      -h|--help)
            usage 0 ;;

      -b|--build-only)
            shift
            __build_only__=true ;;

      -d|--debug)
            shift
            __debug__=true ; __debug_level__=$1
            shift ;;

      -n|--new)
            shift
            __full_path__="$1"
            create_base_config
            exit 0 ;;

      -c|--clean)
            shift
            clean_dist ${1:-3}
            exit 0 ;;

      *)    __invalid__+=( $1 )
            shift ;;
   esac
done

#─────────────────────────────────( validate )──────────────────────────────────
if [[ -e "${GLOBAL_CONF}" ]] ; then
   .load-conf "${GLOBAL_CONF}"
else
   debug 3 "No global configurataion file."
   exit 1
fi

#───────────────────────────────────( init )────────────────────────────────────
mkdir -p "${DATADIR}"/{backup,files,dist}

#───────────────────────────────────( main )────────────────────────────────────
for WORKING_NAME in $(ls "${DATADIR}/files") ; do
   # Reset global variables on each run:
   TOKENS=() ; TOKEN_IDX=0 ; LAST_CREATED_TOKEN=
   WORKING_DIR="${DATADIR}/files/${WORKING_NAME}"
   DIST_DIR="${DATADIR}/dist/${WORKING_NAME}"

   if [[ ! -e "${WORKING_DIR}/base" ]] ; then
      debug 2 "No \`base\` file found in ${WORKING_DIR}"
      continue
   fi

   file_unmodified && continue
   # If this base has already been compiled, deploy 

   load_config ; [[ $? -ne 0 ]] && continue
   # Loads 1) options file, 2) global config, 3) local config

   lex ; parse
   # Reads characters, makes tokens. Read tokens, fills in keys

   deploy
   # Reads tokens, makes files

   debug_output
   # Reads tokens, prints compilation
done
