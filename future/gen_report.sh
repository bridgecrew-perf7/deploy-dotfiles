#!/bin/bash

PROGDIR=$( cd "$(dirname "${BASH_SOURCE[@]}")" ; pwd )
source "$(which mk-colors.sh)"

#═════════════════════════════════╡ GEN DATA ╞══════════════════════════════════
#───────────────────────────────────( table )───────────────────────────────────
declare -A RESULTS_FILE_LIST=()
declare -a pretend_directories=( bashrc vimrc conf conf2 )
declare -a categories=( validate parse build deploy )

for dir in "${pretend_directories[@]}" ; do
   gen_name="_res_$dir"
   declare -A $gen_name
   declare -n rf=$gen_name

   RESULTS_FILE_LIST[$dir]=$gen_name

   for category in "${categories[@]}" ; do
      rf[$category]=$(shuf -i0-1 -n1)
   done
done

res="${bwh}${rst}\t${bwh}validate${rst}\t${bwh}parse${rst}\t${bwh}build${rst}\t${bwh}deploy${rst}"

for rname in "${!RESULTS_FILE_LIST[@]}" ; do
   rpath="${RESULTS_FILE_LIST[$rname]}"
   declare -n rfile=$rpath

   rv="${bwh}${rname}${rst}"
   for category in "${categories[@]}" ; do
      if [[ ${rfile[$category]} -eq 0 ]] ; then
         symbol="✔" ; color="${bgr}"
      else
         symbol="✘" ; color="${brd}"
      fi
      rv+="\t${color}${symbol}${rst}"
   done

   res+="$rv"
done

col=$(echo -e "$res" | column -t -s $'\t')

#─────────────────────────────────( overview )──────────────────────────────────
total=${#RESULTS_FILE_LIST[@]}

built_success=$total
deployed_success=$total

for rname in "${!RESULTS_FILE_LIST[@]}" ; do
   rpath="${RESULTS_FILE_LIST[$rname]}"
   declare -n rfile=$rpath

   built_success=$((built_success - ${rfile[build]}))
   deployed_success=$((deployed_success - ${rfile[deploy]}))
done

[[ $built_success -eq $total ]] && build_color="${bgr}" || build_color="${brd}"
[[ $deployed_success -eq $total ]] && deployed_color="${bgr}" || deployed_color="${brd}"

#════════════════════════════════╡ PRINT DATA ╞═════════════════════════════════
clear ; cat <<EOF | less -r
──────────────────────────────────( overview )──────────────────────────────────
built:    ${build_color}${built_success}/$total${rst}
deployed: ${deployed_color}${deployed_success}/${total}${rst}

$col

#──────────────────────────────────( details )──────────────────────────────────
EOF
