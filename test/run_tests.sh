#!/usr/bin/env bash

set -e

LINE_SPACES=${LINE_SPACES:-48}
MYDIR="$(realpath "$(dirname ${0})")"
nDPId_test_EXEC="$(realpath "${2:-"${MYDIR}/../nDPId-test"}")"
NETCAT_EXEC="nc -q 0 -l 127.0.0.1 9000"
JSON_VALIDATOR="$(realpath "${3:-"${MYDIR}/../examples/py-schema-validation/py-schema-validation.py"}")"
SEMN_VALIDATOR="$(realpath "${4:-"${MYDIR}/../examples/py-semantic-validation/py-semantic-validation.py"}")"

function usage()
{
cat <<EOF
usage: ${0} [path-to-nDPI-source-root] \\
    [path-to-nDPId-test-exec] [path-to-nDPId-JSON-validator] [path-to-nDPId-SEMANTIC-validator]

    path-to-nDPId-test-exec defaults to         ${nDPId_test_EXEC}
    path-to-nDPId-JSON-validator defaults to    ${JSON_VALIDATOR}
    path-to-nDPId-SEMANTIC-validator default to ${SEMN_VALIDATOR}
EOF
return 0
}

if [ $# -eq 0 -a -x "${MYDIR}/../libnDPI/tests/pcap" ]; then
    nDPI_SOURCE_ROOT="${MYDIR}/../libnDPI"
elif [ $# -ne 1 -a $# -ne 2 -a $# -ne 3 -a $# -ne 4 ]; then
    usage
    exit 2
else
    nDPI_SOURCE_ROOT="$(realpath "${1}")"
fi

LOCKFILE="$(realpath "${0}").lock"

touch "${LOCKFILE}"
exec 42< "${LOCKFILE}"
flock -x -n 42 || {
    printf '%s\n' "Could not aquire file lock for ${0}. Already running instance?" >&2;
    exit 3;
}
function sighandler()
{
    printf '%s\n' ' Received shutdown SIGNAL, bye' >&2
    pkill -P $$
    wait
    rm -f "${LOCKFILE}"
    exit 4
}
trap sighandler SIGINT SIGTERM

if [ ! -x "${nDPId_test_EXEC}" ]; then
    usage
    printf '\n%s\n' "Required nDPId-test executable does not exist; ${nDPId_test_EXEC}"
    exit 5
fi

nc -h |& head -n1 | grep -qoE '^OpenBSD netcat' || {
    printf '%s\n' "OpenBSD netcat (nc) version required!" >&2;
    printf '%s\n' "Your version: $(nc -h |& head -n1)" >&2;
    exit 6;
}

nDPI_TEST_DIR="$(realpath "${nDPI_SOURCE_ROOT}/tests/pcap")"
cd "${nDPI_TEST_DIR}"

cat <<EOF
nDPId-test: ${nDPId_test_EXEC}
nDPI pcaps: ${nDPI_TEST_DIR} ($(ls -l *.pcap *.pcapng *.cap | wc -l) total)

--------------------------
-- nDPId PCAP diff tests --
--------------------------

EOF

mkdir -p /tmp/nDPId-test-stderr
set +e
TESTS_FAILED=0

${nDPId_test_EXEC} -h 2>/dev/null
if [ $? -ne 1 ]; then
    printf '%s\n' "nDPId-test: ${nDPId_test_EXEC} seems to be an invalid executable"
    exit 7
fi

for pcap_file in *.pcap *.pcapng *.cap; do
    printf '%s\n' "-- CMD: ${nDPId_test_EXEC} $(realpath "${pcap_file}")" \
        >"/tmp/nDPId-test-stderr/${pcap_file}.out"
    printf '%s\n' "-- OUT: ${MYDIR}/results/${pcap_file}.out" \
        >>"/tmp/nDPId-test-stderr/${pcap_file}.out"

    printf "%-${LINE_SPACES}s\t" "${pcap_file}"

    PRINT_SUMMARY=y ${nDPId_test_EXEC} "${pcap_file}" \
        >"${MYDIR}/results/${pcap_file}.out.new" \
        2>>"/tmp/nDPId-test-stderr/${pcap_file}.out"
    nDPId_test_RETVAL=$?

    if [[ ${pcap_file} == fuzz-* ]]; then
        if [ ${nDPId_test_RETVAL} -eq 0 ]; then
            printf '%s\n' '[OK]'
        elif [ ${nDPId_test_RETVAL} -eq 1 ]; then
            # fuzzed PCAPs with a return value of 1 indicates that libpcap failed
            printf '%s\n' '[FAIL][IGNORED]'
        else
            # may be a valid sanitizer/other failure
            printf '%s\n' '[FAIL]'
            printf '%s\n' '----------------------------------------'
            printf '%s\n' "-- STDERR of ${pcap_file}: /tmp/nDPId-test-stderr/${pcap_file}.out"
            cat "/tmp/nDPId-test-stderr/${pcap_file}.out"
        fi
    elif [ ${nDPId_test_RETVAL} -eq 0 ]; then
        if [ ! -r "${MYDIR}/results/${pcap_file}.out" ]; then
            printf '%s\n' '[NEW]'
            mv -v "${MYDIR}/results/${pcap_file}.out.new" \
                  "${MYDIR}/results/${pcap_file}.out"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        elif diff -u0 "${MYDIR}/results/${pcap_file}.out" \
                      "${MYDIR}/results/${pcap_file}.out.new" >/dev/null; then
            printf '%s\n' '[OK]'
        else
            printf '%s\n' '[DIFF]'
            diff -u0 "${MYDIR}/results/${pcap_file}.out" \
                     "${MYDIR}/results/${pcap_file}.out.new"
            mv -v "${MYDIR}/results/${pcap_file}.out.new" \
                  "${MYDIR}/results/${pcap_file}.out"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        printf '%s\n' '[FAIL]'
        printf '%s\n' '----------------------------------------'
        printf '%s\n' "-- STDERR of ${pcap_file}: /tmp/nDPId-test-stderr/${pcap_file}.out"
        cat "/tmp/nDPId-test-stderr/${pcap_file}.out"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    rm -f "${MYDIR}/results/${pcap_file}.out.new"
done

function validate_results()
{
    prefix_str="${1}"
    pcap_file="$(basename ${2})"
    result_file="${3}"
    validator_exec="${4}"

    printf "%s %-$((${LINE_SPACES} - ${#prefix_str}))s\t" "${prefix_str}" "${pcap_file}"
    printf '%s\n' "-- ${prefix_str}" >>"/tmp/nDPId-test-stderr/${pcap_file}.out"

    if [ ! -r "${result_file}" ]; then
        printf ' %s\n' '[MISSING]'
        return 1
    fi
    if [[ ${pcap_file} == fuzz-* ]]; then
        printf ' %s\n' '[SKIPPED]'
        return 0
    fi

    # Note that the grep command is required as we generate a summary in the results file. (PRINT_SUMMARY=y)
    cat "${result_file}" | grep -vE '^~~.*$' | ${NETCAT_EXEC} &
    nc_pid=$!
    printf '%s\n' "-- ${validator_exec}" >>"/tmp/nDPId-test-stderr/${pcap_file}.out"
    ${validator_exec} 2>>"/tmp/nDPId-test-stderr/${pcap_file}.out"
    if [ $? -eq 0 ]; then
        printf ' %s\n' '[OK]'
    else
        printf ' %s\n' '[FAIL]'
        printf '%s\n' '----------------------------------------'
        printf '%s\n' "-- STDERR of ${pcap_file}: /tmp/nDPId-test-stderr/${pcap_file}.out"
        cat "/tmp/nDPId-test-stderr/${pcap_file}.out"
        return 1
    fi
    kill -SIGTERM ${nc_pid} 2>/dev/null
    wait ${nc_pid} 2>/dev/null

    return 0
}

cat <<EOF

--------------------------------
-- SCHEMA/SEMANTIC Validation --
--------------------------------

netcat (OpenBSD) exec + args: ${NETCAT_EXEC}

EOF

cd "${MYDIR}"
for out_file in results/*.out; do
    pcap_file="${nDPI_TEST_DIR}/$(basename ${out_file%.out})"
    if [ ! -r "${pcap_file}" ]; then
        printf "%-${LINE_SPACES}s\t%s\n" "$(basename ${pcap_file})" '[MISSING]'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        validate_results "SCHEMA  " "${pcap_file}" "${out_file}" \
            "${JSON_VALIDATOR} --host 127.0.0.1 --port 9000"
        if [ $? -ne 0 ]; then
            TESTS_FAILED=$((TESTS_FAILED + 1))
            continue
        fi

        validate_results "SEMANTIC" "${pcap_file}" "${out_file}" \
            "${SEMN_VALIDATOR} --host 127.0.0.1 --port 9000 --strict"
        if [ $? -ne 0 ]; then
            TESTS_FAILED=$((TESTS_FAILED + 1))
            continue
        fi
    fi
done

if [ ${TESTS_FAILED} -eq 0 ]; then
cat <<EOF

--------------------------
-- All tests succeeded. --
--------------------------
EOF
    exit 0
else
cat <<EOF

*** ${TESTS_FAILED} tests failed. ***
EOF
    exit 1
fi
