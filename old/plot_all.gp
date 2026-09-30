# --- 1. Throughput USL ---
set terminal pdf enhanced font 'Helvetica,11' size 5.2in,3.4in
set output 'consul_throughput_usl.pdf'
set title "HashiCorp Consul KV - Throughput Scalability Curve" font "Helvetica-Bold,12" offset 0,0.5
set xlabel "Concurrent Clients (N / VUs)" offset 0,-0.5
set ylabel "Throughput (kop/s)" offset -0.5,0
set xrange [0:250]
set yrange [0:*]
set xtics 25
set grid dt 3 lc rgb "#d0d0d0"
set key right bottom box spacing 1.3
plot 'consul_metrics_clean.dat' using 1:2 title "Empirical Throughput (Consistent Reads)" \
     with linespoints lw 2 pt 7 ps 0.7 lc rgb "#0275d8"

# --- 2. Latency Profile ---
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
