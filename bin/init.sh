#!/bin/bash

# Start monitoring environment
if [ "$OS_VIRT" == "docker" ]; then
	docker run -d --name glances --pid host --privileged --network host --restart=unless-stopped -e GLANCES_OPT="-q --export influxdb2 --time 2" glances
	docker run -d --name rapl --pid host --privileged --network host --restart=unless-stopped rapl
else
	sudo apptainer instance start --env "GLANCES_OPT=-q --export influxdb2 --time 2" "${GLANCES_HOME}"/glances.sif glances
	sudo apptainer instance start "${RAPL_HOME}"/rapl.sif rapl
fi

CPUFREQ_STARTED=0
while [ "${CPUFREQ_STARTED}" -eq 0 ]
do
  "${CPUFREQ_HOME}"/get-freq.sh > /dev/null 2>&1 &
  CPUFREQ_PID=$!
  sleep 1
  if ps -p "${CPUFREQ_PID}" > /dev/null; then
    CPUFREQ_STARTED=1
    m_echo "CPUfreq succesfully started"
  else
    m_err "Error while starting CPUfreq. Trying again."
  fi
done