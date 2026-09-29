#!/bin/bash
OUTPUT_FILE="consul_usl_data.dat"

# Cabeçalho alinhado
printf "%-6s %-16s %-14s %-14s %-14s %-14s %-14s\n" \
  "# N" "Throughput(req/s)" "Avg_Lat" "Med_Lat" "P90_Lat" "P95_Lat" "Max_Lat" > "$OUTPUT_FILE"

CONCURRENCY_LEVELS="1 2 3 4 5 6 7 8 9 10 12 14 16 18 20 24 28 32 26 40 50 60 70 80 90 100 110 120 130 140 150 160 170 180 190 200 210 220 230 240"
DURATION="10s"

echo "=========================================================================================="
echo "A executar Benchmark USL com extração direta via Awk"
echo "=========================================================================================="

for N in $CONCURRENCY_LEVELS; do
    echo "------------------------------------------------------------------------------------------"
    echo "A executar teste com N=$N VUs concorrentes..."
    
    # Captura todo o output do k6 (stdout e stderr) para uma variável
    OUTPUT=$(docker run --rm -i --net consul-net grafana/k6 run - \
      --vus "$N" --duration "$DURATION" 2>&1 << 'EOF'
import http from 'k6/http';
export default function () {
  http.get('http://consul-server:8500/v1/kv/config/app-service?consistent');
}
EOF
)

    # Imprime o output no terminal para poderes ver o progresso
    echo "$OUTPUT"

    # Extrai cada valor diretamente do texto do k6
    TPUT=$(echo "$OUTPUT" | grep "http_reqs\." | head -n 1 | awk '{print $3}' | sed 's/\/s//')
    
    # Extrai os campos da linha http_req_duration
    DUR_LINE=$(echo "$OUTPUT" | grep "http_req_duration\." | head -n 1)
    AVG=$(echo "$DUR_LINE" | sed -n 's/.*avg=\([^ ]*\).*/\1/p')
    MED=$(echo "$DUR_LINE" | sed -n 's/.*med=\([^ ]*\).*/\1/p')
    MAX=$(echo "$DUR_LINE" | sed -n 's/.*max=\([^ ]*\).*/\1/p')
    P90=$(echo "$DUR_LINE" | sed -n 's/.*p(90)=\([^ ]*\).*/\1/p')
    P95=$(echo "$DUR_LINE" | sed -n 's/.*p(95)=\([^ ]*\).*/\1/p')

    # Salva na tabela se capturou com sucesso
    if [ -n "$TPUT" ]; then
        printf "%-6s %-16s %-14s %-14s %-14s %-14s %-14s\n" \
          "$N" "$TPUT" "$AVG" "$MED" "$P90" "$P95" "$MAX" >> "$OUTPUT_FILE"
        echo ">> Gravado no ficheiro: N=$N | Throughput=$TPUT | Avg=$AVG | P95=$P95"
    else
        echo ">> Aviso: Não foi possível extrair os valores para N=$N"
    fi

    sleep 2
done

echo "=========================================================================================="
echo "Concluído com sucesso! Conteúdo de $OUTPUT_FILE:"
echo "=========================================================================================="
cat "$OUTPUT_FILE"