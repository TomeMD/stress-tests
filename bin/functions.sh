#!/bin/sh

export LOG_FILE=${LOG_DIR}/${WORKLOAD}.log

function get_date {
    DATE=`date '+%d/%m/%Y %H:%M:%S'`
}

export -f get_date

function m_echo() {
    get_date
    echo -e "\e[48;5;2m[$DATE INFO]\e[0m $@"
    echo "$DATE > $@" >> "${LOG_FILE}"
}

export -f m_echo

function m_err() {
    get_date
    echo -e "\e[48;5;1m[$DATE ERR ]\e[0m $@" >&2
    echo "$DATE > $@" >> "${LOG_FILE}"
}

export -f m_err

function m_warn() {
    get_date
    echo -e "\e[48;5;208m[$DATE WARN]\e[0m $@"
    echo "$DATE > $@" >> "${LOG_FILE}"
}

export -f m_warn

function show_logo() {
  echo " _____ ____   ____     ____  _                      ____ ____  _   _ "
  echo "|_   _/ ___| / ___|   / ___|| |_ _ __ ___  ___ ___ / ___|  _ \| | | |"
  echo "  | | \___ \| |  _    \___ \| __| '__/ _ \/ __/ __| |   | |_) | | | |"
  echo "  | |  ___) | |_| |    ___) | |_| | |  __/\__ \__ \ |___|  __/| |_| |"
  echo "  |_| |____/ \____|___|____/ \__|_|  \___||___/___/\____|_|    \___/ "
  echo "                 |_____|                                             "
  echo ""
}

export -f show_logo

function print_conf() {
    show_logo
    m_echo "Writing output to ${LOG_FILE}"
    m_echo "OS Virtualization Technology = ${OS_VIRT}"
    m_echo "Workload = ${WORKLOAD}"
    if [ "${WORKLOAD}" == "stress-system" ]; then
      m_echo "Stress-system stressors = [${STRESSORS}]"
      m_echo "CPU Stressor Load Types = [${LOAD_TYPES}]"
    fi
}

export -f print_conf

function print_time() {
	m_echo "${NAME} CPU TIME: $(bc <<< "scale=9; $(($2 - $1)) / 1000000000")" | tee -a "${LOG_FILE}"
}

export -f print_time

function print_timestamp() {
	local DESCRIPTION=$1
	m_echo "${NAME} ${DESCRIPTION}: $(date -u "+%Y-%m-%d %H:%M:%S%z")"
	echo "${NAME} ${DESCRIPTION}: $(date -u "+%Y-%m-%d %H:%M:%S%z")" >> "${TIMESTAMPS_FILE}"
}

export -f print_timestamp

function set_sequential_cores() {
  MAX=$1
  CORES=""
  for (( i=0; i<MAX; i++ )); do
      if [ "$i" -ne 0 ]; then
        CORES+=","
    fi
    CORES+="$i"
  done
}

export -f set_sequential_cores

function set_cores() {
	CORE_0="${CPUS_FIRST_CORE[$((CPU % 2))]}"
	CORE_1=$((CORE_0 + PAIR_OFFSET))
	if [ -z "${CORES}" ]; then
	  CORES+="${CORE_0},${CORE_1}"
	else
	  CORES+=",${CORE_0},${CORE_1}"
	fi
	CPUS_FIRST_CORE[$((CPU % 2))]=$((CORE_0 + INCREMENT))
}

export -f set_cores

function start_cpufreq_core() {
	CPUFREQ_STARTED=0
	while [ "${CPUFREQ_STARTED}" -eq 0 ]
	do
		  echo "${CPUFREQ_HOME}/get-freq-core.sh ${CORES}"
  		"${CPUFREQ_HOME}"/get-freq-core.sh "${CORES}" > /dev/null 2>&1 &
  		CORE_CPUFREQ_PID=$!
  		sleep 1
  		if ps -p "${CORE_CPUFREQ_PID}" > /dev/null; then
    			CPUFREQ_STARTED=1
    			m_echo "CPUfreq per core succesfully started"
  		else
    			m_err "Error while starting CPUfreq per core. Trying again."
  		fi
	done
}

export -f start_cpufreq

function stop_cpufreq_core() {
  kill "${CORE_CPUFREQ_PID}"

  if ps -p "${CORE_CPUFREQ_PID}" > /dev/null; then
     m_err "Error while killing CPUfreq per core process"
  else
     m_echo "CPUfreq per core process succesfully stopped"
  fi
}

export -f stop_cpufreq

function run_stress-system() {
	print_timestamp "STRESS-TEST (CORES = $CORES) START"
	if [ "${OS_VIRT}" == "docker" ]; then
		docker run --rm --name stress-system -it stress-system -l "${LOAD}" -s "${STRESSORS}" --cpu-load-types "${LOAD_TYPES}" -c "${CORES}" -t 2m >> "${LOG_FILE}" 2>&1
	else
		apptainer run "${STRESS_CONTAINER_DIR}"/stress.sif -l "${LOAD}" -s "${STRESSORS}" --cpu-load-types "${LOAD_TYPES}" -c "${CORES}" -t 2m >> "${LOG_FILE}" 2>&1
	fi
	print_timestamp "STRESS-TEST (CORES = $CORES) STOP"
	sleep 15
}

export -f run_stress-system

function run_geekbench() {
	print_timestamp "GEEKBENCH (CORES = $CORES) START"
	taskset -c "${CORES}" "${GEEKBENCH_HOME}"/geekbench_x86_64 | tee -a "${LOG_FILE}"
	print_timestamp "GEEKBENCH (CORES = $CORES) STOP"
	sleep 15
}

export -f run_geekbench

function run_npb_kernel() {
	local COMMAND="while true; do ${NPB_HOME}/${1} | tee -a ${LOG_FILE}; done"
	NUM_THREADS=1
	while [ "${NUM_THREADS}" -le "${THREADS}" ]
	do
      set_sequential_cores ${NUM_THREADS}
	    start_cpufreq_core
	    print_timestamp "NPB START"
	    export OMP_NUM_THREADS="${NUM_THREADS}"
	    taskset -c "${CORES}" timeout 5m bash -c "${COMMAND}"
	    NUM_THREADS=$(( NUM_THREADS * 2 ))
	    print_timestamp "NPB STOP"
	    stop_cpufreq_core
	done
}

export -f run_npb_kernel

function idle_cpu() {
	print_timestamp "IDLE START"
	sleep 30
	print_timestamp "IDLE STOP"
	sleep 5
}

export -f idle_cpu

################################################################################################
# run_experiment <NAME> <PAIR_OFFSET> <INCREMENT> <CPU_SWITCH> <TOTAL_PAIRS> <TEST_FUNCTION>
################################################################################################
# <NAME>: Name of the experiment
#
# <TOTAL_PAIRS>: Total pairs of cores.
#
# <PAIR_OFFSET>: Distance between the cores in a pair, for example, if we use pairs 
# (0,16), (1,17),... PAIR_OFFSET will be 16.
#
# <INCREMENT>: Increment of the number of the first core of each pair between iterations. This 
# INCREMENT is applied independently to the pairs of each CPU. Examples:
#     cores=(0 1 2 3 4 5 6 7) INCREMENT=2
#     cores=(0 16 1 17 2 18 3 19) INCREMENT=1
#
# <CPU_SWITCH>: Frequency in iterations to switch between CPUs. Set 0 to avoid switching 
# between CPUs.
#
# <TEST_FUNCTION>: Benchmark/tool to stress CPU.
#
################################################################################################
function run_experiment() { 
	NAME=$1
	TOTAL_PAIRS=$2
	PAIR_OFFSET=$3
	INCREMENT=$4
	CPU_SWITCH=$5
	TEST_FUNCTION=$6
	if [ "${CPU_SWITCH}" -eq $((PHY_CORES_PER_CPU / 2)) ]; then
		CPUS_FIRST_CORE=(0 $((PHY_CORES_PER_CPU * 2))) # (1st physical core cpu0, 1st logical core cpu 0)
	else
		CPUS_FIRST_CORE=(0 "${PHY_CORES_PER_CPU}") # (1st physical core cpu0, 1st physical core cpu 1)
	fi
	CPU=0
	CORES=""
	LOAD=200
	local PAIRS_COUNT=0
	local START_TEST=$(date +%s%N)
	while [ "${PAIRS_COUNT}" -lt "${TOTAL_PAIRS}" ]; do
	    set_cores
	    start_cpufreq_core
	    "$TEST_FUNCTION"
	    idle_cpu
	    stop_cpufreq_core
	    LOAD=$((LOAD + 200))
	    PAIRS_COUNT=$((PAIRS_COUNT + 1))
		if [ "${CPU_SWITCH}" -ne 0 ] && [ $((PAIRS_COUNT % CPU_SWITCH)) -eq 0 ]; then
			CPU=$((CPU + 1))
		fi
	done
	local END_TEST=$(date +%s%N)
  print_time "${START_TEST}" "${END_TEST}"
}

export -f run_experiment