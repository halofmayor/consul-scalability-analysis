#!/bin/bash
set -euo pipefail

#   ./analyze_usl.sh \
#       read_stress_results.csv \
#       write_stress_results.csv \
#       1200.5 0.01 0.0001 \
#       950.2 0.05 0.0008

export LC_ALL=C.UTF-8

# Valida argumentos, necessário porque às vezes eu reuso tabelas
# e corro risco de apagar gráficos -Lucas

if [[ $# -ne 8 ]]; then
    echo "Uso:"
    echo "  $0 <read_csv> <write_csv> \\"
    echo "     <read_lambda> <read_delta> <read_kappa> \\"
    echo "     <write_lambda> <write_delta> <write_kappa>"
    exit 1
fi

READ_FILE="$1"
WRITE_FILE="$2"

READ_LAMBDA="$3"
READ_DELTA="$4"
READ_KAPPA="$5"

WRITE_LAMBDA="$6"
WRITE_DELTA="$7"
WRITE_KAPPA="$8"

READ_PLOT="usl_read.png"
WRITE_PLOT="usl_write.png"
THROUGHPUT_PLOT="usl_throughput.png"
TRANSFORMED_PLOT="usl_transformed.png"

#verificar dependências
if ! command -v gnuplot >/dev/null 2>&1; then
    echo "ERRO: gnuplot não encontrado." >&2
    exit 1
fi

if [[ ! -f "$READ_FILE" ]]; then
    echo "ERRO: ficheiro não encontrado: $READ_FILE" >&2
    exit 1
fi

if [[ ! -f "$WRITE_FILE" ]]; then
    echo "ERRO: ficheiro não encontrado: $WRITE_FILE" >&2
    exit 1
fi

#validação numérica, failsafe caso algo tenha corrido mal no benchmark
is_number() {
    [[ "$1" =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]
}

for PARAM_NAME in \
    READ_LAMBDA READ_DELTA READ_KAPPA \
    WRITE_LAMBDA WRITE_DELTA WRITE_KAPPA
do
    PARAM_VALUE="${!PARAM_NAME}"

    if ! is_number "$PARAM_VALUE"; then
        echo "ERRO: $PARAM_NAME não é um número válido: '$PARAM_VALUE'." >&2
        exit 1
    fi
done

echo "================================================================================"
echo "Geração de gráficos USL"
echo "================================================================================"
echo

echo "READ  : $READ_FILE"
echo "  lambda = $READ_LAMBDA"
echo "  delta  = $READ_DELTA"
echo "  kappa  = $READ_KAPPA"
echo

echo "WRITE : $WRITE_FILE"
echo "  lambda = $WRITE_LAMBDA"
echo "  delta  = $WRITE_DELTA"
echo "  kappa  = $WRITE_KAPPA"
echo

#determinar maior N

MAX_READ_N=$(
    awk -F',' '
        NR > 1 && $1 != "" {
            if ($1 + 0 > max)
                max = $1 + 0
        }
        END {
            print max
        }
    ' "$READ_FILE"
)

MAX_WRITE_N=$(
    awk -F',' '
        NR > 1 && $1 != "" {
            if ($1 + 0 > max)
                max = $1 + 0
        }
        END {
            print max
        }
    ' "$WRITE_FILE"
)

N_MAX=$(
    awk -v a="$MAX_READ_N" -v b="$MAX_WRITE_N" '
        BEGIN {
            if (a > b)
                print a
            else
                print b
        }
    '
)

if [[ -z "$N_MAX" || "$N_MAX" == "0" ]]; then
    echo "ERRO: não foi possível determinar os valores de N." >&2
    exit 1
fi

# SCRIPT GNUPLOT:

GNUPLOT_SCRIPT="$(mktemp)"
trap 'rm -f "$GNUPLOT_SCRIPT"' EXIT

cat > "$GNUPLOT_SCRIPT" << EOF

set terminal pngcairo size 1200,700 enhanced font "Arial,11"

set grid back
set border linewidth 1.2

set datafile separator ","

read_usl(x) = (${READ_LAMBDA} * x) / \
              (1.0 \
               + ${READ_DELTA} * (x - 1.0) \
               + ${READ_KAPPA} * x * (x - 1.0))

write_usl(x) = (${WRITE_LAMBDA} * x) / \
               (1.0 \
                + ${WRITE_DELTA} * (x - 1.0) \
                + ${WRITE_KAPPA} * x * (x - 1.0))

# CONFIGS DE JANELA

set xrange [1:${N_MAX} * 1.05]

set key top left box opaque

set output "${READ_PLOT}"

set title "Consul READ scalability - USL"
set xlabel "N"
set ylabel "Throughput (req/s)"

plot \
    "${READ_FILE}" using 1:2 \
        with points pt 7 ps 1.4 \
        title "Measured READ", \
    read_usl(x) \
        with lines lw 2.5 \
        title sprintf("USL: lambda=%.4f, delta=%.6f, kappa=%.6f", \
                      ${READ_LAMBDA}, \
                      ${READ_DELTA}, \
                      ${READ_KAPPA})


set output "${WRITE_PLOT}"

set title "Consul WRITE scalability - USL"
set xlabel "N"
set ylabel "Throughput (req/s)"

plot \
    "${WRITE_FILE}" using 1:2 \
        with points pt 7 ps 1.4 \
        title "Measured WRITE", \
    write_usl(x) \
        with lines lw 2.5 \
        title sprintf("USL: lambda=%.4f, delta=%.6f, kappa=%.6f", \
                      ${WRITE_LAMBDA}, \
                      ${WRITE_DELTA}, \
                      ${WRITE_KAPPA})


set output "${THROUGHPUT_PLOT}"

set title "Consul scalability - READ vs WRITE"
set xlabel "N"
set ylabel "Throughput (req/s)"

plot \
    "${READ_FILE}" using 1:2 \
        with points pt 7 ps 1.2 \
        title "Measured READ", \
    read_usl(x) \
        with lines lw 2 \
        title "READ USL", \
    "${WRITE_FILE}" using 1:2 \
        with points pt 5 ps 1.2 \
        title "Measured WRITE", \
    write_usl(x) \
        with lines lw 2 \
        title "WRITE USL"

# =============================================================================
# 4. Throughput por nó
#
# Mostra:
#
#   X(N) / N
#
# onde:
#
#   X(N) = throughput total
#   N    = número de VUs / servidores
#
# A curva teórica corresponde ao modelo USL:
#
#   X(N) / N =
#
#       lambda
#       -----------------------------------------------
#       1 + delta*(N-1) + kappa*N*(N-1)
#
# =============================================================================

read_per_node(x) = \
    (${READ_LAMBDA}) / \
    (1.0 \
     + ${READ_DELTA} * (x - 1.0) \
     + ${READ_KAPPA} * x * (x - 1.0))

write_per_node(x) = \
    (${WRITE_LAMBDA}) / \
    (1.0 \
     + ${WRITE_DELTA} * (x - 1.0) \
     + ${WRITE_KAPPA} * x * (x - 1.0))

set output "${TRANSFORMED_PLOT}"

set title "Consul throughput per node"
set xlabel "N"
set ylabel "Throughput / N (req/s per node)"

plot \
    "${READ_FILE}" using 1:(\$2/\$1) \
        with points pt 7 ps 1.2 \
        title "Measured READ", \
    read_per_node(x) \
        with lines lw 2 \
        title "READ USL", \
    "${WRITE_FILE}" using 1:(\$2/\$1) \
        with points pt 5 ps 1.2 \
        title "Measured WRITE", \
    write_per_node(x) \
        with lines lw 2 \
        title "WRITE USL"

EOF

gnuplot "$GNUPLOT_SCRIPT"

echo
echo "================================================================================"
echo "Gráficos gerados"
echo "================================================================================"

echo "  $READ_PLOT"
echo "  $WRITE_PLOT"
echo "  $THROUGHPUT_PLOT"
echo "  $TRANSFORMED_PLOT"

echo
echo "Análise concluída."