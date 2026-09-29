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

echo "=========================================================================================="
echo "Experimento 1: Read Scalability"
echo "=========================================================================================="
echo "Duração por teste: $DURATION"
echo "Níveis de concorrência: $CONCURRENCY_LEVELS"
echo

# =============================================================================
# Limpeza prévia
# =============================================================================

docker rm -f "$SERVER_NAME" 2>/dev/null || true
docker network rm "$NETWORK_NAME" 2>/dev/null || true

# =============================================================================
# Criar rede
# =============================================================================

docker network create "$NETWORK_NAME"

# =============================================================================
# Iniciar Consul
# =============================================================================

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

# =============================================================================
# Aguardar Consul
# =============================================================================

echo "A aguardar inicialização do Consul..."

until curl -s http://localhost:8500/v1/status/leader | grep -q ':[0-9]'; do
    sleep 1
done

echo "Consul pronto!"

# =============================================================================
# Criar entrada KV
# =============================================================================

curl -s -X PUT \
  -d '{"status":"ok"}' \
  http://localhost:8500/v1/kv/config/app-service \
  > /dev/null

echo "Entrada KV criada."
echo

# =============================================================================
# Executar cada nível de concorrência
# =============================================================================

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

    # =========================================================================
    # Mostrar output
    # =========================================================================

    echo "$OUTPUT"
    echo

    # =========================================================================
    # Extrair throughput
    # =========================================================================

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

    # Remover espaços
    RPS=$(echo "$RPS" | sed 's/[[:space:]]//g')

    # =========================================================================
    # Validar throughput
    # =========================================================================

    if [[ -z "$RPS" ]]; then
        echo "ERRO: não foi possível extrair o throughput para N=$N." >&2
        exit 1
    fi

    # =========================================================================
    # Guardar resultado no CSV
    # =========================================================================

    printf "%s,%.2f\n" "$N" "$RPS" >> "$OUTPUT_FILE"

done

# =============================================================================
# Final
# =============================================================================

echo
echo "=========================================================================================="
echo "Experimento concluído."
echo "=========================================================================================="
echo "Dados: $OUTPUT_FILE"
echo
echo "Níveis testados:"
echo "$CONCURRENCY_LEVELS"
