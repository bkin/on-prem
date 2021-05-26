#!/bin/bash
if [[ ! -x "$1" ]]
then
  cat <<EOF
Usage: $0 LIB_OR_EXE [PATH]

Will create LIB_OR_EXE.comp_dir or PATH/\$(basename LIB_OR_EXE).comp_dir with the content of DW_AT_comp_dir
Will also translate DW_AT_comp_dir to something suitable for pernosco for the following DW_AT_comp_dir's:
  * /b/work/... -> Replace by /b/devel/XYZ/...
  * /root/.conan/... -> Replace by something in your conan data path
EOF
  exit 1
fi
if [[ -d "$2" ]]
then
  TARGET="$2/$( basename "$1" ).comp_dir"
else
  TARGET="$1.comp_dir"
fi

SONAME=$( echo $( basename "$1" ) | sed 's/mmap_\(pack\|clone\)_[0-9]\+_//' )
COMP_DIR=$( objdump -Wi  "$1" | awk '/DW_AT_comp_dir/ { print $NF; exit }' )


if [[ -v MOUNTED_WORK ]] && [[ $COMP_DIR =~ /b/work ]]
then
  COMP_DIR2=$( echo $COMP_DIR | sed "s+^/b/work+$MOUNTED_WORK+" )
elif hash conan 2>/dev/null && [[ $COMP_DIR =~ ^/root/.conan ]]
then
  CONAN_STORAGE=$( conan config get storage.path )
  COMP_DIR2=$( echo $COMP_DIR | sed "s@^/root/.conan/data\(/.*\)/building/build/[a-z0-9]\+\(/.*\)@$CONAN_STORAGE\1/stable/source\2@" )
fi

if [[ -d "$COMP_DIR2" ]]
then
  COMP_DIR="$COMP_DIR2"
fi

if [[ -n "$COMP_DIR" ]]
then
  echo "$SONAME" "$COMP_DIR" > "$TARGET"
else
  touch "$TARGET"
fi
