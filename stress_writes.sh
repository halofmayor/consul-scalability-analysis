#!/bin/bash
set -euo pipefail

# =============================================================================
# Parâmetros
#
# Uso:
#   ./stress_writes.sh
#   ./stress_writes.sh 30s
#   ./stress_writes.sh 30s "1 3 5 7"
#   ./stress_writes.sh 30s "1 3 5 7" 32
#
# Parâmetros:
#   $1 = duração de cada teste
#   $2 = tamanhos do cluster Consul
#   $3 = número fixo de VUs do k6
#
# IMPORTANTE:
#   N representa agora o número de servidores Consul,
#   e NÃO o número de clientes concorrentes.
# =============================================================================

DURATION="${1:-10s}"
CLUSTER_SIZES="${2:-1 3 5 7}"
CLIENT_VUS="${3:-32}"

NETWORK_NAME="consul-net"
SERVER_PREFIX="consul-server"
OUTPUT_FILE="write_stress_results.csv"

echo "=========================================================================================="
echo "Experimento: Write Scalability / Consenso Raft"
echo "=========================================================================================="
echo "Duração por teste: $DURATION"
echo "Tamanhos do cluster: $CLUSTER_SIZES"
echo "VUs do k6: $CLIENT_VUS"
echo

# =============================================================================
# Função de limpeza
# =============================================================================

cleanup() {

    echo
    echo "A limpar containers Consul..."

    for N in $CLUSTER_SIZES; do
        docker rm -f "${SERVER_PREFIX}-${N}" 2>/dev/null || true
    done

    # Remove qualquer container com o prefixo consul-server-
    docker ps -a --format '{{.Names}}' |
        grep "^${SERVER_PREFIX}-" |
        xargs -r docker rm -f 2>/dev/null || true

    docker network rm "$NETWORK_NAME" 2>/dev/null || true
}

# Garantir limpeza caso o script seja interrompido
trap cleanup EXIT

# =============================================================================
# Limpeza prévia
# =============================================================================

docker ps -a --format '{{.Names}}' |
    grep "^${SERVER_PREFIX}" |
    xargs -r docker rm -f 2>/dev/null || true

docker network rm "$NETWORK_NAME" 2>/dev/null || true

# =============================================================================
# Criar rede
# =============================================================================

docker network create "$NETWORK_NAME"

# =============================================================================
# Executar cada tamanho de cluster
# =============================================================================

for N in $CLUSTER_SIZES; do

    echo
    echo "=========================================================================================="
    echo "A criar cluster Consul com N=$N servidores..."
    echo "=========================================================================================="

    # =========================================================================
    # Criar servidores Consul
    # =========================================================================

    for ((i=1; i<=N; i++)); do

        SERVER_NAME="${SERVER_PREFIX}-${i}"

        echo "A iniciar $SERVER_NAME..."

        if [[ "$i" -eq 1 ]]; then

            # -----------------------------------------------------------------
            # Primeiro servidor
            #
            # Este servidor serve como ponto inicial de descoberta.
            # -----------------------------------------------------------------

            docker run -d \
              --name "$SERVER_NAME" \
              --net "$NETWORK_NAME" \
              --cpus="1.0" \
              --memory="512m" \
              -p 8500:8500 \
              hashicorp/consul:latest \
              agent \
              -server \
              -node="$SERVER_NAME" \
              -bootstrap-expect="$N" \
              -ui \
              -client=0.0.0.0

        else

            # -----------------------------------------------------------------
            # Servidores seguintes
            #
            # Estes servidores fazem retry-join ao primeiro servidor.
            # O bootstrap-expect garante que o cluster espera pelos N servidores.
            # -----------------------------------------------------------------

            docker run -d \
              --name "$SERVER_NAME" \
              --net "$NETWORK_NAME" \
              --cpus="1.0" \
              --memory="512m" \
              hashicorp/consul:latest \
              agent \
              -server \
              -node="$SERVER_NAME" \
              -bootstrap-expect="$N" \
              -retry-join="${SERVER_PREFIX}-1" \
              -ui \
              -client=0.0.0.0

        fi

    done

    # =========================================================================
    # Aguardar os servidores entrarem no cluster
    # =========================================================================

    echo
    echo "A aguardar os $N servidores entrarem no cluster..."

    until true; do

        MEMBERS=$(
            curl -s http://localhost:8500/v1/agent/members 2>/dev/null |
            grep -o '"Status":1' |
            wc -l |
            tr -d ' '
        )

        if [[ "$MEMBERS" -eq "$N" ]]; then
            break
        fi

        echo "  Servidores disponíveis: $MEMBERS/$N"
        sleep 1
    done

    echo "Todos os $N servidores estão presentes no cluster."

    # =========================================================================
    # Aguardar eleição do líder
    # =========================================================================

    echo "A aguardar eleição do líder Raft..."

    until curl -s http://localhost:8500/v1/status/leader |
          grep -q ':[0-9]'; do

        sleep 1

    done

    LEADER=$(
        curl -s http://localhost:8500/v1/status/leader
    )

    echo "Líder eleito: $LEADER"
    echo

    # =========================================================================
    # Pequena pausa para estabilização
    # =========================================================================

    sleep 2

    # =========================================================================
    # Executar benchmark
    #
    # IMPORTANTE:
    #
    # Os VUs permanecem constantes entre os diferentes tamanhos de cluster.
    # O único parâmetro experimental alterado é N = número de servidores.
    #
    # Os requests são enviados sempre para consul-server-1.
    # Se este não for o líder, o agente encaminha a operação para o líder,
    # mantendo o custo de comunicação/consenso associado ao cluster.
    # =========================================================================

    echo "------------------------------------------------------------------------------------------"
    echo "A executar benchmark com N=$N servidores..."
    echo "VUs: $CLIENT_VUS"
    echo "Duração: $DURATION"
    echo "------------------------------------------------------------------------------------------"

    OUTPUT=$(docker run --rm -i \
      --net "$NETWORK_NAME" \
      grafana/k6 run - \
      --vus "$CLIENT_VUS" \
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
        'http://consul-server-1:8500/v1/kv/benchmark/write',
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

    # =========================================================================
    # Remover cluster antes do próximo tamanho
    # =========================================================================

    echo
    echo "A remover cluster N=$N..."

    for ((i=1; i<=N; i++)); do
        docker rm -f "${SERVER_PREFIX}-${i}" 2>/dev/null || true
    done

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
echo "Tamanhos de cluster testados:"
echo "$CLUSTER_SIZES"
echo
echo "Número de VUs mantido constante:"
echo "$CLIENT_VUS"