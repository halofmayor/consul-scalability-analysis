#!/bin/bash
set -euo pipefail

#   ./analyze_usl.sh \
#       read_stress_results.csv \
#       write_stress_results.csv \
#       1200.5 0.01 0.0001 \
#       950.2 0.05 0.0008

#   formato csv:

#   1,1234.56
#   2,2345.67
#   ...

export LC_ALL=C.UTF-8

# =============================================================================
# Validar argumentos
# =============================================================================

if [[ $# -ne 8 ]]; then
    echo "Uso:"
    echo "  $0 <read_csv> <write_csv> \\"
    echo "     <read_lambda> <read_delta> <read_kappa> \\"
    echo "     <write_lambda> <write_delta> <write_kappa>"
    echo
    echo "Exemplo:"
    echo "  $0 read_stress_results.csv write_stress_results.csv \\"
    echo "     1200.5 0.01 0.0001 \\"
    echo "     950.2 0.05 0.0008"
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

# =============================================================================
# Ficheiros de output
# =============================================================================

READ_PLOT="usl_read.png"
WRITE_PLOT="usl_write.png"
THROUGHPUT_PLOT="usl_throughput.png"
TRANSFORMED_PLOT="usl_transformed.png"

# =============================================================================
# Verificar dependências
# =============================================================================

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

# =============================================================================
# Validar parâmetros numéricos
# =============================================================================

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

# =============================================================================
# Mostrar configuração
# =============================================================================

echo "================================================================================"
echo "Geração de gráficos - Universal Scalability Law"
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

# =============================================================================
# Determinar maior N
# =============================================================================

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

# =============================================================================
# Criar script temporário do gnuplot
# =============================================================================

GNUPLOT_SCRIPT="$(mktemp)"
trap 'rm -f "$GNUPLOT_SCRIPT"' EXIT

cat > "$GNUPLOT_SCRIPT" << EOF

set terminal pngcairo size 1200,700 enhanced font "Arial,11"

set grid back
set border linewidth 1.2

set datafile separator ","

# =============================================================================
# Funções USL
# =============================================================================

read_usl(x) = (${READ_LAMBDA} * x) / \
              (1.0 \
               + ${READ_DELTA} * (x - 1.0) \
               + ${READ_KAPPA} * x * (x - 1.0))

write_usl(x) = (${WRITE_LAMBDA} * x) / \
               (1.0 \
                + ${WRITE_DELTA} * (x - 1.0) \
                + ${WRITE_KAPPA} * x * (x - 1.0))

# =============================================================================
# Janela dos gráficos
# =============================================================================

set xrange [1:${N_MAX} * 1.05]

set key top left box opaque

# =============================================================================
# 1. READ
# =============================================================================

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

# =============================================================================
# 2. WRITE
# =============================================================================

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

# =============================================================================
# 3. READ vs WRITE
# =============================================================================

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
# 4. Transformação N / X(N)
#
# Os pontos representam os valores medidos.

# A curva teórica corresponde à transformação do modelo USL:
#
#   N / X(N)
#       = [1 + delta*(N-1) + kappa*N*(N-1)] / lambda
#
# =============================================================================

read_transformed(x) = \
    (1.0 \
     + ${READ_DELTA} * (x - 1.0) \
     + ${READ_KAPPA} * x * (x - 1.0)) / ${READ_LAMBDA}

write_transformed(x) = \
    (1.0 \
     + ${WRITE_DELTA} * (x - 1.0) \
     + ${WRITE_KAPPA} * x * (x - 1.0)) / ${WRITE_LAMBDA}

set output "${TRANSFORMED_PLOT}"

set title "USL transformed data: N / X(N)"
set xlabel "N"
set ylabel "N / Throughput (s)"

plot \
    "${READ_FILE}" using 1:(\$1/\$2) \
        with points pt 7 ps 1.2 \
        title "Measured READ", \
    read_transformed(x) \
        with lines lw 2 \
        title "READ USL", \
    "${WRITE_FILE}" using 1:(\$1/\$2) \
        with points pt 5 ps 1.2 \
        title "Measured WRITE", \
    write_transformed(x) \
        with lines lw 2 \
        title "WRITE USL"

EOF

# =============================================================================
# Executar gnuplot
# =============================================================================

gnuplot "$GNUPLOT_SCRIPT"

# =============================================================================
# Final
# =============================================================================

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