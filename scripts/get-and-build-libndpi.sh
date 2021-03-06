#!/usr/bin/env bash

set -e

LOCKFILE="$(realpath "${0}").lock"
touch "${LOCKFILE}"
exec 42< "${LOCKFILE}"
flock -x -n 42 || {
    printf '%s\n' "Could not aquire file lock for ${0}. Already running instance?" >&2;
    exit 1;
}

set -x

cd "$(dirname "${0}")/.."
if [ -d ./.git ]; then
    git submodule update --init ./libnDPI
fi

cd ./libnDPI
DEST_INSTALL="${DEST_INSTALL:-$(realpath ./install)}"
MAKE_PROGRAM="${MAKE_PROGRAM:-make -j4}"
if [ ! -z "${CROSS_COMPILE_TRIPLET}" ]; then
    HOST_ARG="--host=${CROSS_COMPILE_TRIPLET}"
else
    HOST_ARG=""
fi
./autogen.sh --prefix="${DEST_INSTALL}" --with-only-libndpi ${HOST_ARG}
${MAKE_PROGRAM} install

rm -f "${LOCKFILE}"
