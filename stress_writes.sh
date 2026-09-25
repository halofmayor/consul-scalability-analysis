#!/bin/bash
set -euo pipefail

# =============================================================================
# Parâmetros
#
# Uso:
#   ./stress_writes.sh
#   ./stress_writes.sh 30s
#   ./stress_writes.sh 30s "1 2 4 8 16 32 64 128 200 240"
#
# =============================================================================

DURATION="${1:-10s}"
CONCURRENCY_LEVELS="${2:-1 2 4 8 16 32 64 128 200 240}"

NETWORK_NAME="consul-net"
SERVER_NAME="consul-server"
OUTPUT_FILE="write_stress_results.dat"

echo "=========================================================================================="
echo "Experimento 2: Write Scalability"
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
# Aguardar Consul ficar pronto
# =============================================================================

echo "A aguardar inicialização do Consul..."

until curl -s http://localhost:8500/v1/status/leader | grep -q ':[0-9]'; do
    sleep 1
done

echo "Consul pronto!"
echo

# =============================================================================
# Cabeçalho do ficheiro
# Mantido exatamente igual ao experimento de reads.
# =============================================================================

printf "%-6s %-16s %-14s %-14s %-14s %-14s %-14s\n" \
  "# N" \
  "Throughput(req/s)" \
  "Avg_Lat" \
  "Med_Lat" \
  "P90_Lat" \
  "P95_Lat" \
  "Max_Lat" \
  > "$OUTPUT_FILE"

# =============================================================================
# Função para extrair uma métrica do output do k6
# =============================================================================

extract_metric() {
    local metric="$1"
    local line="$2"

    echo "$line" |
        sed -n "s/.*${metric}=\\([^[:space:]]*\\).*/\\1/p"
}

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
    const payload = JSON.stringify({
        status: "ok",
        vu: __VU,
        iteration: __ITER
    });

    http.put(
        'http://consul-server:8500/v1/kv/benchmark/write',
        payload,
        {
            headers: {
                'Content-Type': 'application/json'
            }
        }
    );
}
EOF
    )

    # =========================================================================
    # Mostrar output do k6
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

    # =========================================================================
    # Encontrar linha de latência
    # =========================================================================

    DUR_LINE=$(
        echo "$OUTPUT" |
        awk '
            /^[[:space:]]*http_req_duration[.]+:/ &&
            $0 !~ /expected_response/ {
                print
                exit
            }
        '
    )

    # =========================================================================
    # Extrair latências
    # =========================================================================

    AVG=$(extract_metric "avg" "$DUR_LINE")
    MED=$(extract_metric "med" "$DUR_LINE")
    P90=$(extract_metric "p(90)" "$DUR_LINE")
    P95=$(extract_metric "p(95)" "$DUR_LINE")
    MAX=$(extract_metric "max" "$DUR_LINE")

    # Remover unidade, caso presente
    RPS=$(echo "$RPS" | sed 's/[[:space:]]//g')
    AVG=$(echo "$AVG" | sed 's/ms$//')
    MED=$(echo "$MED" | sed 's/ms$//')
    P90=$(echo "$P90" | sed 's/ms$//')
    P95=$(echo "$P95" | sed 's/ms$//')
    MAX=$(echo "$MAX" | sed 's/ms$//')

    # =========================================================================
    # Validar resultados
    # =========================================================================

    if [[ -z "$RPS" ]]; then
        echo "ERRO: não foi possível extrair o throughput para N=$N." >&2
        exit 1
    fi

    if [[ -z "$DUR_LINE" ]]; then
        echo "ERRO: não foi possível encontrar http_req_duration para N=$N." >&2
        exit 1
    fi

    if [[ -z "$AVG" || \
          -z "$MED" || \
          -z "$P90" || \
          -z "$P95" || \
          -z "$MAX" ]]; then

        echo "ERRO: não foi possível extrair todas as métricas de latência para N=$N." >&2
        echo
        echo "Linha encontrada:" >&2
        echo "$DUR_LINE" >&2
        exit 1
    fi

    # =========================================================================
    # Guardar resultado
    # =========================================================================

    printf "%-6s %-16.2f %-14.2f %-14.2f %-14.2f %-14.2f %-14.2f\n" \
      "$N" \
      "$RPS" \
      "$AVG" \
      "$MED" \
      "$P90" \
      "$P95" \
      "$MAX" \
      | tee -a "$OUTPUT_FILE"

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