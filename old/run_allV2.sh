#!/bin/bash
set -e

NETWORK_NAME="consul-net"
SERVER_NAME="consul-server"
OUTPUT_FILE="consul_usl_data.dat"
PLOT_USL_PNG="consul_usl_fit.png"
PLOT_LAT_PNG="consul_latency.png"
DURATION="10s"
CONCURRENCY_LEVELS="1 2 4 8 16 32 64 128 200 240"

# Limpeza prévia
docker rm -f "$SERVER_NAME" 2>/dev/null || true
docker network rm "$NETWORK_NAME" 2>/dev/null || true

# Criação da rede e container
docker network create "$NETWORK_NAME"

docker run -d --name "$SERVER_NAME" \
  --net "$NETWORK_NAME" \
  --cpus="1.0" \
  --memory="512m" \
  -p 8500:8500 \
  hashicorp/consul:latest agent -server -bootstrap-expect=1 -ui -client=0.0.0.0

echo "A aguardar inicialização e eleição do líder do Consul..."
until curl -s http://localhost:8500/v1/status/leader | grep -q ':[0-9]'; do
  sleep 1
done
echo "Consul pronto!"

# Criar a chave KV que o k6 irá ler
curl -s -X PUT -d '{"status":"ok"}' http://localhost:8500/v1/kv/config/app-service > /dev/null

# Cabeçalho do ficheiro de dados
printf "%-6s %-16s %-14s %-14s %-14s %-14s %-14s\n" \
  "# N" "Throughput(req/s)" "Avg_Lat" "Med_Lat" "P90_Lat" "P95_Lat" "Max_Lat" > "$OUTPUT_FILE"

echo "=========================================================================================="
echo "A executar Benchmark USL com extração direta via Awk/Sed"
echo "=========================================================================================="

for N in $CONCURRENCY_LEVELS; do
    echo "------------------------------------------------------------------------------------------"
    echo "A executar teste com N=$N VUs concorrentes..."
    
    OUTPUT=$(docker run --rm -i --net "$NETWORK_NAME" grafana/k6 run - \
      --vus "$N" --duration "$DURATION" 2>&1 << 'EOF'
import http from 'k6/http';
export default function () {
  http.get('http://consul-server:8500/v1/kv/config/app-service?consistent');
}
EOF
)

    # Extração de métricas com tratamento de unidades (ms/µs/s -> ms numérico)
    RPS=$(echo "$OUTPUT" | grep "http_reqs\." | head -n 1 | awk '{print $3}' | tr -d '/s')
    DUR_LINE=$(echo "$OUTPUT" | grep "http_req_duration\." | head -n 1)

    AVG=$(echo "$DUR_LINE" | sed -n 's/.*avg=\([^ ]*\).*/\1/p' | sed -e 's/ms//' -e 's/µs/*0.001/' -e 's/s/*1000/' | bc -l)
    MED=$(echo "$DUR_LINE" | sed -n 's/.*med=\([^ ]*\).*/\1/p' | sed -e 's/ms//' -e 's/µs/*0.001/' -e 's/s/*1000/' | bc -l)
    P90=$(echo "$DUR_LINE" | sed -n 's/.*p(90)=\([^ ]*\).*/\1/p' | sed -e 's/ms//' -e 's/µs/*0.001/' -e 's/s/*1000/' | bc -l)
    P95=$(echo "$DUR_LINE" | sed -n 's/.*p(95)=\([^ ]*\).*/\1/p' | sed -e 's/ms//' -e 's/µs/*0.001/' -e 's/s/*1000/' | bc -l)
    MAX=$(echo "$DUR_LINE" | sed -n 's/.*max=\([^ ]*\).*/\1/p' | sed -e 's/ms//' -e 's/µs/*0.001/' -e 's/s/*1000/' | bc -l)

    printf "%-6s %-16.2f %-14.2f %-14.2f %-14.2f %-14.2f %-14.2f\n" \
      "$N" "$RPS" "$AVG" "$MED" "$P90" "$P95" "$MAX" | tee -a "$OUTPUT_FILE"
done

echo "=========================================================================================="
echo "A gerar gráficos USL com o Gnuplot..."
echo "=========================================================================================="

# 1. Gráfico USL (Throughput medido + Curva Ajustada da USL)
gnuplot << EOF
set terminal pngcairo size 1000,600 enhanced font 'Arial,11'
set output '${PLOT_USL_PNG}'

set title "Consul KV Consistent Reads: Universal Scalability Law (USL)" font ',13'
set xlabel "Concorrência / VUs (N)"
set ylabel "Throughput (req/s)"
set grid back lc rgb "#e0e0e0"

# Definição matemática do modelo USL
X(N) = (gamma * N) / (1.0 + sigma * (N - 1.0) + kappa * N * (N - 1.0))

# Valores iniciais para regressão não linear
gamma = 1000.0
sigma = 0.05
kappa = 0.0005

# Ajuste por mínimos quadrados aos dados recolhidos (coluna 1=N, coluna 2=Throughput)
fit X(x) '${OUTPUT_FILE}' using 1:2 via gamma, sigma, kappa

set key top left box opaque
plot '${OUTPUT_FILE}' using 1:2 with points pt 7 ps 1.5 lc rgb "#1f77b4" title "Medições Reais (k6)", \
     X(x) with lines lw 2.5 lc rgb "#d62728" title sprintf("USL Fit: γ=%.1f, σ=%.4f, κ=%.5f", gamma, sigma, kappa)
EOF

# 2. Gráfico de Latências
gnuplot << EOF
set terminal pngcairo size 1000,600 enhanced font 'Arial,11'
set output '${PLOT_LAT_PNG}'

set title "Consul KV Consistent Reads: Latência vs Concorrência" font ',13'
set xlabel "Concorrência / VUs (N)"
set ylabel "Latência (ms)"
set grid back lc rgb "#e0e0e0"
set key top left box opaque

plot '${OUTPUT_FILE}' using 1:3 with linespoints pt 5 ps 1 lw 2 lc rgb "#2ca02c" title "Latência Média", \
     '${OUTPUT_FILE}' using 1:5 with linespoints pt 7 ps 1 lw 2 lc rgb "#ff7f0e" title "P90", \
     '${OUTPUT_FILE}' using 1:6 with linespoints pt 9 ps 1 lw 2 lc rgb "#d62728" title "P95"
EOF

echo "Processo concluído!"
echo "- Dados:    $OUTPUT_FILE"
echo "- Curva USL: $PLOT_USL_PNG"
echo "- Latência: $PLOT_LAT_PNG"