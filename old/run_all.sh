#!/bin/bash
set -e

NETWORK_NAME="consul-net"
SERVER_NAME="consul-server"
OUTPUT_DAT="consul_metrics_clean.dat"
DURATION="10s"
CONCURRENCY_LEVELS="1 2 4 6 8 10 12 16 20 25 30 40 60 80 100 140 180 200 240"

echo "=========================================================================="
echo " [1/5] LIMPEZA E PREPARAÇÃO DO AMBIENTE DOCKER"
echo "=========================================================================="
docker rm -f $SERVER_NAME 2>/dev/null || true
docker network rm $NETWORK_NAME 2>/dev/null || true

echo "A criar rede Docker isolada ($NETWORK_NAME)..."
docker network create $NETWORK_NAME

echo "=========================================================================="
echo " [2/5] INICIALIZAÇÃO DO HASHICORP CONSUL (KV STORE)"
echo "=========================================================================="
docker run -d --name $SERVER_NAME \
  --net $NETWORK_NAME \
  --cpus="1.0" \
  --memory="512m" \
  -p 8500:8500 \
  hashicorp/consul:latest agent -server -bootstrap-expect=1 -ui -client=0.0.0.0 > /dev/null

echo -n "A aguardar pela prontidão da API HTTP do Consul..."
until curl -s http://localhost:8500/v1/status/leader | grep -q "8300"; do
    echo -n "."
    sleep 1
done
echo " [PRONTO]"

echo "A povoar chave de teste no KV store..."
curl -s --request PUT \
  --data '{"db_host": "db.internal", "db_port": 5432, "timeout": 30}' \
  http://localhost:8500/v1/kv/config/app-service > /dev/null

echo "=========================================================================="
echo " [3/5] EXECUÇÃO DO BENCHMARK USL (GRAFANA K6)"
echo "=========================================================================="
printf "%-6s %-18s %-14s %-14s %-14s %-14s\n" \
  "# N" "Throughput_kops" "Avg_Lat_ms" "Med_Lat_ms" "P95_Lat_ms" "Max_Lat_ms" > "$OUTPUT_DAT"

# Cria um script k6 local estático para evitar problemas de piping
cat << 'K6_SCRIPT' > test_kv.js
import http from 'k6/http';
export default function () {
  http.get('http://consul-server:8500/v1/kv/config/app-service?consistent');
}
K6_SCRIPT

for N in $CONCURRENCY_LEVELS; do
    echo -n ">> A testar N=$N VUs ($DURATION)... "
    
    # Executa o k6 injetando o script e extraindo o JSON pelo stdout via python
    METRICS=$(docker run --rm -i --net $NETWORK_NAME grafana/k6 run \
      --vus "$N" --duration "$DURATION" --summary-export=/dev/stdout -q - < test_kv.js 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tput = data['metrics']['http_reqs']['values']['rate'] / 1000.0
    dur = data['metrics']['http_req_duration']['values']
    print(f\"{tput:.3f} {dur['avg']:.3f} {dur['med']:.3f} {dur['p(95)']:.3f} {dur['max']:.3f}\")
except Exception as e:
    pass
")

    if [ -n "$METRICS" ]; then
        read -r TPUT AVG MED P95 MAX <<< "$METRICS"
        printf "%-6s %-18s %-14s %-14s %-14s %-14s\n" \
          "$N" "$TPUT" "$AVG" "$MED" "$P95" "$MAX" >> "$OUTPUT_DAT"
        echo "OK: $TPUT kop/s | Avg: $AVG ms | P95: $P95 ms"
    else
        echo "FALHA na recolha"
    fi

    sleep 1
done

rm -f test_kv.js

echo "=========================================================================="
echo " [4/5] GERAÇÃO DOS GRÁFICOS (GNUPLOT)"
echo "=========================================================================="

cat << 'GP_EOF' > plot_all.gp
# --- Throughput USL ---
set terminal pdf enhanced font 'Helvetica,11' size 5.2in,3.4in
set output 'consul_throughput_usl.pdf'
set title "HashiCorp Consul KV - Throughput Scalability Curve" font "Helvetica-Bold,12" offset 0,0.5
set xlabel "Concurrent Clients (N / VUs)" offset 0,-0.5
set ylabel "Throughput (kop/s)" offset -0.5,0
set xrange [0:250]
set yrange [0:35]
set xtics 25
set ytics 5
set grid dt 3 lc rgb "#d0d0d0"
set key right bottom box spacing 1.3
plot 'consul_metrics_clean.dat' using 1:2 title "Empirical Throughput (Consistent Reads)" \
     with linespoints lw 2 pt 7 ps 0.7 lc rgb "#0275d8"

# --- Latency Profile ---
set output 'consul_latency.pdf'
set title "HashiCorp Consul KV - Latency Profile Under Stress" font "Helvetica-Bold,12" offset 0,0.5
set xlabel "Concurrent Clients (N / VUs)" offset 0,-0.5
set ylabel "Latency (ms)" offset -0.5,0
set xrange [0:250]
set yrange [0:*]
set xtics 25
set grid dt 3 lc rgb "#d0d0d0"
set key left top box spacing 1.3
plot 'consul_metrics_clean.dat' using 1:5 title "P95 Tail Latency" with linespoints lw 2 pt 7 ps 0.7 lc rgb "#d9534f", \
     'consul_metrics_clean.dat' using 1:3 title "Average Latency" with linespoints lw 2 pt 5 ps 0.7 lc rgb "#5cb85c"
GP_EOF

gnuplot plot_all.gp
echo "Gráficos gerados com sucesso: consul_throughput_usl.pdf e consul_latency.pdf"

echo "=========================================================================="
echo " [5/5] PROCESSO CONCLUÍDO COM SUCESSO!"
echo "=========================================================================="
