#!/bin/bash
set -euo pipefail

# =============================================================================
# Parâmetros
#
# Uso:
#   ./stress_reads.sh
#   ./stress_reads.sh 30s
#   ./stress_reads.sh 30s "1 2 4 8 16 32 64 128 200 240"
#
# =============================================================================

DURATION="${1:-10s}"
CONCURRENCY_LEVELS="${2:-1 2 4 8 16 32 64 128 200 240}"

NETWORK_NAME="consul-net"
SERVER_NAME="consul-server"
OUTPUT_FILE="read_stress_results.csv"

#limpeza prévia
docker rm -f "$SERVER_NAME" 2>/dev/null || true
docker network rm "$NETWORK_NAME" 2>/dev/null || true
docker network create "$NETWORK_NAME"

docker run -d \
  --name "$SERVER_NAME" \
  --net "$NETWORK_NAME" \
  --cpus="1.0" \
  --memory="512m" \
  -p 8500:8500 \
  hashicorp/consul:latest \
  agent \
  -server \
  -bootstrap-expect=1 \
  -ui \
  -client=0.0.0.0

echo "A aguardar inicialização do Consul..."

until curl -s http://localhost:8500/v1/status/leader | grep -q ':[0-9]'; do
    sleep 1
done

echo "Consul pronto!"

curl -s -X PUT \
  -d '{"status":"ok"}' \
  http://localhost:8500/v1/kv/config/app-service \
  > /dev/null

echo "Entrada KV criada."
echo

for N in $CONCURRENCY_LEVELS; do

    echo
    echo "------------------------------------------------------------------------------------------"
    echo "A executar teste com N=$N VUs..."
    echo "Duração: $DURATION"
    echo "------------------------------------------------------------------------------------------"

    # =========================================================================
    # Executar k6
    # =========================================================================

    OUTPUT=$(docker run --rm -i \
      --net "$NETWORK_NAME" \
      grafana/k6 run - \
      --vus "$N" \
      --duration "$DURATION" \
      --summary-time-unit=ms \
      --summary-trend-stats="avg,min,med,max,p(90),p(95)" \
      2>&1 << 'EOF'
import http from 'k6/http';

export default function () {
    http.get(
        'http://consul-server:8500/v1/kv/config/app-service?consistent'
    );
}
EOF
    )

    echo "$OUTPUT"
    echo

    #extrai throughput
    RPS=$(
        echo "$OUTPUT" |
        awk '
            /^[[:space:]]*http_reqs[.]+:/ {
                split($0, parts, ":")

                value = parts[2]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

                split(value, fields, /[[:space:]]+/)

                gsub(/\/s$/, "", fields[2])

                print fields[2]
                exit
            }
        '
    )

    #remove espaços
    RPS=$(echo "$RPS" | sed 's/[[:space:]]//g')

    #check de troughput, se não existir, o run_repetitions segue quando não devia.
    if [[ -z "$RPS" ]]; then
        echo "ERRO: não foi possível extrair o throughput para N=$N." >&2
        exit 1
    fi

    printf "%s,%.2f\n" "$N" "$RPS" >> "$OUTPUT_FILE"

done

echo
echo "=========================================================================================="
echo "Experimento concluído."
echo "=========================================================================================="
echo "Dados: $OUTPUT_FILE"
echo
echo "Níveis testados:"
echo "$CONCURRENCY_LEVELS"
