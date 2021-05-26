#!/bin/bash

BASENAME=$(basename "$0")
usage() {
  cat <<EOF
$BASENAME TPS Core Team, May 2021

Usage:
  To make a recording:
    $BASENAME <prog> <args>
    $BASENAME record <prog> <args>

  To call pernosco build/serve (on your machine):
    $BASENAME build <args>
    $BASENAME serve <args>

  Beta: To call pernosco build+serve on a different machine:
    $BASENAME submit HOST [tracedir]

  To call pernosco serve and also make the port publicly available:
    $BASENAME share <args>

The first two invocations call 'rr record' and you can also just add parameters
for 'rr record' before your program name.
EOF
}

if python3 --version | grep -q 'Python 3.[0-7]'
then
  pernosco() {
    python3.8 $( which pernosco ) "$@"
  }
fi

case "$1" in
  -h | --help | help) usage; exit 0;;
  build) shift; DO_BUILD=1;;
  only-build) shift; DO_ONLY_BUILD=1;;
  serve) shift; DO_SERVE=1;;
  share) shift; DO_SHARE=1;;
  submit) shift; DO_SUBMIT=1;;
  record) shift; DO_RECORD=1;;
  *) DO_RECORD=1;;
esac

echoexec() {
  echo "Running '$*'" >&2
  "$@"
  exit $?
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

if [[ -d "$TRACEDIR" ]]
then
  if [[ -d "$MOUNTED_WORK" ]]
  then
    TRACEDIR=${TRACEDIR//\/b\/work/$MOUNTED_WORK}
  fi

  # Now append $TRACEDIR as the last argument for 'pernosco serve|build'
  set -- "${@}" "$TRACEDIR"
fi

if (( DO_SUBMIT == 1 ))
then
  # Bail out on errors here
  set -e

  ID_RSA_FILE=/b/devel/pernosco/pernosco-on-prem/pernosco.id_rsa 
  # We need to do a few things here. First, we have to run `pernosco
  # package-build` locally to gather everything that is required into the trace dir
  #
  # Then we have to scp that to HOST
  # Alternative: set up container with pernosco distribution, copy that over to host
  # TODO: Work something out regarding credentials used for scp
  #
  # Then, on HOST, we have to first run `pernosco only-build` and then `p serve`
  #
  # The HOST needs to have 'p' installed
  HOST=$1
  shift

  ssh_cmd() {
    ssh -t -i "$ID_RSA_FILE" -o PasswordAuthentication=no pernosco@"$HOST" "$@"
  }

  export TIMEFORMAT=" (%R s)"

  scp_to_host_cmd() {
    rsync -ah --no-inc-recursive --info=progress2 --exclude 'db.*/' -e "ssh -i $ID_RSA_FILE -o PasswordAuthentication=no" "$@"
  }

  # Check if we can connect to $HOST with the right credentials.
  # These should be set up on $HOST like this:
  #   sudo useradd --shell /bin/bash -d /home/pernosco -U pernosco
  #   sudo usermod -a -G docker pernosco
  #   su pernosco
  #   cat /PATH/TO/SPECIAL/id_rsa.pub > ~/.ssh/authorized_keys
  #   Krams zu /opt/pernosco, ~/.bash_aliases bei tps-docker-srv-02 abgucken
  if ! ssh_cmd "cd /opt/pernosco/on-prem && git pull"
  then
    echo Connecting to "$HOST" and upgrading /opt/pernosco/on-prem failed

    if [[ -d "$HOST" ]]
    then
      echo "$HOST is a directory. Proper syntax is:"
      echo "  pernosco submit HOST TRACE-DIRECTORY"
      echo "or, when using a default trace directory:"
      echo "  pernosco submit HOST"
    fi

    exit 1
  fi

  # Require TRACEDIR for the time being
  if (( $# == 0 ))
  then
    echo "For the time being, please provide a trace directory for 'p submit'"
    exit 1
  fi

  TRACEDIR=$( realpath $1 )
  shift

  if ! [[ -d "$TRACEDIR" ]]
  then
    echo "$TRACEDIR is not a directory"
    echo "For the time being, please provide a trace directory for 'p submit'"
    exit 1
  fi

  if (( $# > 0 ))
  then
    echo "Unsupported additional arguments $@"
    exit 1
  fi

  # Step 0: Check if we had already submitted something
  if ! [[ -f "$TRACEDIR/submit_id" ]]
  then
    </dev/urandom tr --complement --delete 'a-zA-Z0-9' | head -c33 > "$TRACEDIR/submit_id"
  fi
  SUBMIT_ID=$( cat "$TRACEDIR/submit_id" )

  # You can call submit more than once. We skip the db build if possible and only serve
  # Step 1: Run `pernosco package-build`
  echo "Preparing trace for submit"
  if [[ -f "$TRACEDIR/package_complete" ]]
  then
    echo "Trace already packaged"
  else
    # TODO Gather some info for --substitute and --copy-sources from the executable files in $TRACEDIR
    #pernosco package-build $MOUNTED_WORK/rr/tps-6 --substitute DEFAULT=$MOUNTED_WORK/cmake_builds/release --copy-sources $MOUNTED_WORK
    time pernosco package-build "$TRACEDIR" && touch "$TRACEDIR/package_complete"
  fi

  echo "Building the pernosco db for /opt/pernosco/submit/$SUBMIT_ID/trace on $HOST"
  if ssh_cmd "test -f /opt/pernosco/submit/$SUBMIT_ID/build_complete"
  then
    echo "Build already complete"
  else
    # Step 2: Copy trace to host
    echo -n "Copy $TRACEDIR to $HOST:/opt/pernosco/submit/$SUBMIT_ID/trace"
    ssh_cmd mkdir -p "/opt/pernosco/submit/$SUBMIT_ID"

    # To be able to put some other stuff into $SUBMIT_ID, we us "/trace" as a
    # target name for the trace dir contents
    scp_to_host_cmd "$TRACEDIR/" "pernosco@$HOST:/opt/pernosco/submit/$SUBMIT_ID/trace"

    time ssh_cmd "p only-build /opt/pernosco/submit/$SUBMIT_ID/trace && touch /opt/pernosco/submit/$SUBMIT_ID/build_complete"
  fi

  echo "Serving results Building the pernosco db for /opt/pernosco/submit/$SUBMIT_ID/trace on $HOST"
  ssh_cmd "p share --storage /opt/pernosco/submit/$SUBMIT_ID/trace /opt/pernosco/submit/$SUBMIT_ID/trace"
  exit $?
elif (( DO_BUILD == 1 ))
then
  echoexec pernosco build "$@"
elif (( DO_ONLY_BUILD == 1 ))
then
  echoexec pernosco only-build "$@"
elif (( DO_SERVE == 1 ))
then
  # TODO: Provide help for --sources
  echoexec pernosco serve "$@"
elif (( DO_SHARE == 1 ))
then
  # Run pernosco serve + wait until we know ip+port
  echo "Running 'pernosco serve $*' and serving, too"
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
