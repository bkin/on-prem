#!/bin/bash

BASENAME=$(basename "$0")
usage() {
  cat <<EOF
$BASENAME TPS Core Team, May 2021

Usage:
  To make a recording:
    $BASENAME <prog> <args>
    $BASENAME record <prog> <args>

  To call pernosco build/serve:
    $BASENAME build <args>
    $BASENAME serve <args>

  To call pernosco serve and also make the port publicly available:
    $BASENAME share <args>

The first two invocations call 'rr record' and you can also just add parameters
for 'rr record' before your program name.
EOF
}

case "$1" in
  -h | --help | help) usage; exit 0;;
  build) shift; DO_BUILD=1;;
  serve) shift; DO_SERVE=1;;
  share) shift; DO_SHARE=1;;
  record) shift; DO_RECORD=1;;
  *) DO_RECORD=1;;
esac

echoexec() {
  echo "Running '$*'" >&2
  exec "$@"
}

if (( DO_RECORD == 1 ))
then
  echoexec rr record "$@"
fi

# All other commands take an optional trace directory last
# We help b users here by replacing /b/work with $MOUNTED_WORK
#
# This helps because /b/work is only available from within a mount namespace
# and docker has no access to that.
if (( $# > 0 )) && [[ -d ${*: -1} ]]
then
  TRACEDIR=${*: -1}

  # Remove TRACEDIR argument for now
  set -- "${@:1:$(($#-1))}"
fi

# Even if the user has not provided a trace directory, _RR_TRACE_DIR might
# exist and point to somewhere within /b/work
if ! [[ -d "$TRACEDIR" ]] && [[ -d "$_RR_TRACE_DIR" ]]
then
  TRACEDIR="$_RR_TRACE_DIR"/latest-trace
fi

if [[ -d "$TRACEDIR" ]] && [[ -d "$MOUNTED_WORK" ]]
then
  TRACEDIR=${TRACEDIR//\/b\/work/$MOUNTED_WORK}

  # Now append $TRACEDIR as the last argument for 'pernosco serve|build'
  set -- "${@}" "$TRACEDIR"
fi

if (( DO_BUILD == 1 ))
then
  # TODO MV Maybe support doing this on a different machine
  echoexec pernosco build "$@"
elif (( DO_SERVE == 1 ))
then
  # TODO: Provide help for --sources
  echoexec pernosco serve "$@"
elif (( DO_SHARE == 1 ))
then
  # Run pernosco serve + wait until we know ip+port
  echo "Running 'pernosco serve $*'"
  coproc PERNOSCO_SERVE { pernosco serve "$@"; }
  # shellcheck disable=SC2064
  trap "kill -SIGINT $PERNOSCO_SERVE_PID; wait" EXIT

  while read -r line <&"${PERNOSCO_SERVE[0]}"
  do
    echo "$line"
    LAUNCH_RX="Appserver launched at http://([0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)):([0-9]+)/index.html"
    if [[ "$line" =~ $LAUNCH_RX ]]
    then
      PERNOSCO_IP="${BASH_REMATCH[1]}"
      PERNOSCO_IP_LAST="${BASH_REMATCH[2]}"
      PERNOSCO_PORT="${BASH_REMATCH[3]}"
      LOCALPORT=$(( "$PERNOSCO_IP_LAST" + "$PERNOSCO_PORT" ))
      break
    fi
  done


  # Build tunnel and wait
  socat TCP-LISTEN:"$LOCALPORT",fork TCP:"$PERNOSCO_IP:$PERNOSCO_PORT" &
  SOCAT_PID=$!
  sleep 0.5
  if kill -0 $SOCAT_PID 2> /dev/null
  then
    # shellcheck disable=SC2064
    trap "kill -SIGINT $PERNOSCO_SERVE_PID $SOCAT_PID; wait" EXIT
    echo "Appserver shared at http://$( hostname -A | cut -f1 -d' ' ):$LOCALPORT/index.html"
  fi

  wait
fi
