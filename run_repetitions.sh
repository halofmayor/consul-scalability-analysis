#!/bin/bash
set -euo pipefail

# =============================================================================
# run_repetitions.sh
#
# Corre a varredura completa de:
#   - stress_reads.sh
#   - stress_writes.sh
#
# REPETICOES vezes, guarda cada repetição em ficheiros separados dentro de
# raw_data/:
#   raw_data/read_rep<N>.csv
#   raw_data/write_rep<N>.csv
#
# Depois:
#   1. Agrega as repetições com aggregate_runs.py
#      -> read_stress_results.csv
#      -> write_stress_results.csv
#
#   2. Executa esle-usl-1.0-SNAPSHOT.jar separadamente sobre os dois
#      ficheiros agregados.
#
#   3. Extrai:
#      - lambda
#      - delta
#      - kappa
#
#   4. Passa esses valores ao analyze_usl.sh para gerar os gráficos
#      com a curva USL.
#
# Uso:
#   ./run_repetitions.sh <repeticoes> <duration> "<concurrency levels>"
#
# Exemplo:
#   ./run_repetitions.sh 3 30s "1 2 4 8 16 32 64 128 200 240"
#
# Requisitos:
#   stress_reads.sh
#   stress_writes.sh
#   aggregate_runs.py
#   analyze_usl.sh
#   esle-usl-1.0-SNAPSHOT.jar
#   python3
#   java
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

READ_SCRIPT="$SCRIPT_DIR/stress_reads.sh"
WRITE_SCRIPT="$SCRIPT_DIR/stress_writes.sh"
AGGREGATE_SCRIPT="$SCRIPT_DIR/aggregate_runs.py"
ANALYSIS_SCRIPT="$SCRIPT_DIR/analyze_usl.sh"
USL_JAR="$SCRIPT_DIR/esle-usl-1.0-SNAPSHOT.jar"

RAW_DIR="$SCRIPT_DIR/raw_data"

READ_AGGREGATED="$SCRIPT_DIR/read_stress_results.csv"
WRITE_AGGREGATED="$SCRIPT_DIR/write_stress_results.csv"

usage() {
    echo "Uso:"
    echo "  $0 <repeticoes> <duration> \"<concurrency levels>\""
    echo
    echo "Exemplo:"
    echo "  $0 3 30s \"1 2 4 8 16 32 64 128 200 240\""
    echo
}

if [[ $# -ne 3 ]]; then
    usage
    exit 1
fi

REPS="$1"
DURATION="$2"
CONCURRENCY_LEVELS="$3"

if ! [[ "$REPS" =~ ^[0-9]+$ ]] || [[ "$REPS" -lt 1 ]]; then
    echo "ERRO: número de repetições inválido: '$REPS'." >&2
    exit 1
fi

log() {
    echo
    echo "================================================================================"
    echo "$1"
    echo "================================================================================"
}

fail() {
    echo
    echo "ERRO: $1" >&2
    exit 1
}

# =============================================================================
# Checks dos ficheiros necessários
# =============================================================================

[[ -f "$READ_SCRIPT" ]]      || fail "Não encontrado: $READ_SCRIPT"
[[ -f "$WRITE_SCRIPT" ]]     || fail "Não encontrado: $WRITE_SCRIPT"
[[ -f "$AGGREGATE_SCRIPT" ]] || fail "Não encontrado: $AGGREGATE_SCRIPT"
[[ -f "$ANALYSIS_SCRIPT" ]]  || fail "Não encontrado: $ANALYSIS_SCRIPT"
[[ -f "$USL_JAR" ]]          || fail "Não encontrado: $USL_JAR"

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 não encontrado."
fi

if ! command -v java >/dev/null 2>&1; then
    fail "java não encontrado."
fi

chmod +x "$READ_SCRIPT" "$WRITE_SCRIPT" "$ANALYSIS_SCRIPT"

log "CONFIGURAÇÃO"

echo "Repetições        : $REPS"
echo "Duração por nível : $DURATION"
echo "Níveis            : $CONCURRENCY_LEVELS"
echo "Pasta de trabalho : $SCRIPT_DIR"
echo "USL JAR           : $USL_JAR"

cd "$SCRIPT_DIR"

# =============================================================================
# Preparar pasta de dados brutos
#
# Evita misturar dados desta execução com repetições de execuções anteriores.
# =============================================================================

log "A preparar $RAW_DIR/"

mkdir -p "$RAW_DIR"

rm -f \
    "$RAW_DIR"/read_rep*.csv \
    "$RAW_DIR"/write_rep*.csv

echo "Feito."

# =============================================================================
# Correr REPS repetições
# =============================================================================

for i in $(seq 1 "$REPS"); do

    # =========================================================================
    # READ
    # =========================================================================

    log "REPETIÇÃO $i / $REPS — READ"

    "$READ_SCRIPT" "$DURATION" "$CONCURRENCY_LEVELS"

    [[ -f "$READ_AGGREGATED" ]] ||
        fail "READ da repetição $i não produziu read_stress_results.csv."

    mv \
        "$READ_AGGREGATED" \
        "$RAW_DIR/read_rep${i}.csv"

    echo "Guardado: $RAW_DIR/read_rep${i}.csv"

    # =========================================================================
    # WRITE
    # =========================================================================

    log "REPETIÇÃO $i / $REPS — WRITE"

    "$WRITE_SCRIPT" "$DURATION" "$CONCURRENCY_LEVELS"

    [[ -f "$WRITE_AGGREGATED" ]] ||
        fail "WRITE da repetição $i não produziu write_stress_results.csv."

    mv \
        "$WRITE_AGGREGATED" \
        "$RAW_DIR/write_rep${i}.csv"

    echo "Guardado: $RAW_DIR/write_rep${i}.csv"

done

# =============================================================================
# Agregar repetições
#
# A mediana é calculada por N para READ e WRITE.
# =============================================================================

log "A AGREGAR REPETIÇÕES (mediana por N)"

python3 "$AGGREGATE_SCRIPT"

[[ -f "$READ_AGGREGATED" ]] ||
    fail "Agregação não produziu read_stress_results.csv."

[[ -f "$WRITE_AGGREGATED" ]] ||
    fail "Agregação não produziu write_stress_results.csv."

echo "READ agregado : $READ_AGGREGATED"
echo "WRITE agregado: $WRITE_AGGREGATED"

# =============================================================================
# Calcular parâmetros USL
#
# O JAR produz exatamente:
#
#   Total useful lines read: 6
#   Lambda: 3741.8009056961 Delta: 0.2452552887 Kappa: 0.0074262208
#
# Assumimos que o JAR recebe o ficheiro CSV como único argumento:
#
#   java -jar esle-usl-1.0-SNAPSHOT.jar <csv>
# =============================================================================

log "CÁLCULO DOS PARÂMETROS USL"

# -----------------------------------------------------------------------------
# READ
# -----------------------------------------------------------------------------

echo "A calcular parâmetros USL para READ..."
echo "Ficheiro: $READ_AGGREGATED"

READ_USL_OUTPUT=$(java -jar "$USL_JAR" "$READ_AGGREGATED")

echo "$READ_USL_OUTPUT"

READ_LAMBDA=$(
    echo "$READ_USL_OUTPUT" |
    awk '
        /^Lambda:/ {
            print $2
            exit
        }
    '
)

READ_DELTA=$(
    echo "$READ_USL_OUTPUT" |
    awk '
        /^Lambda:/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "Delta:") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
)

READ_KAPPA=$(
    echo "$READ_USL_OUTPUT" |
    awk '
        /^Lambda:/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "Kappa:") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
)

if [[ -z "$READ_LAMBDA" ||
      -z "$READ_DELTA" ||
      -z "$READ_KAPPA" ]]; then

    fail "Não foi possível extrair lambda/delta/kappa do output do JAR para READ."
fi

echo
echo "READ:"
echo "  Lambda = $READ_LAMBDA"
echo "  Delta  = $READ_DELTA"
echo "  Kappa  = $READ_KAPPA"

# -----------------------------------------------------------------------------
# WRITE
# -----------------------------------------------------------------------------

echo
echo "A calcular parâmetros USL para WRITE..."
echo "Ficheiro: $WRITE_AGGREGATED"

WRITE_USL_OUTPUT=$(java -jar "$USL_JAR" "$WRITE_AGGREGATED")

echo "$WRITE_USL_OUTPUT"

WRITE_LAMBDA=$(
    echo "$WRITE_USL_OUTPUT" |
    awk '
        /^Lambda:/ {
            print $2
            exit
        }
    '
)

WRITE_DELTA=$(
    echo "$WRITE_USL_OUTPUT" |
    awk '
        /^Lambda:/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "Delta:") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
)

WRITE_KAPPA=$(
    echo "$WRITE_USL_OUTPUT" |
    awk '
        /^Lambda:/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "Kappa:") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
)

if [[ -z "$WRITE_LAMBDA" ||
      -z "$WRITE_DELTA" ||
      -z "$WRITE_KAPPA" ]]; then

    fail "Não foi possível extrair lambda/delta/kappa do output do JAR para WRITE."
fi

echo
echo "WRITE:"
echo "  Lambda = $WRITE_LAMBDA"
echo "  Delta  = $WRITE_DELTA"
echo "  Kappa  = $WRITE_KAPPA"

# =============================================================================
# Gerar gráficos
#
# analyze_usl.sh recebe:
#
#   READ CSV
#   WRITE CSV
#   READ lambda
#   READ delta
#   READ kappa
#   WRITE lambda
#   WRITE delta
#   WRITE kappa
# =============================================================================

log "GERAÇÃO DOS GRÁFICOS USL"

"$ANALYSIS_SCRIPT" \
    "$READ_AGGREGATED" \
    "$WRITE_AGGREGATED" \
    "$READ_LAMBDA" \
    "$READ_DELTA" \
    "$READ_KAPPA" \
    "$WRITE_LAMBDA" \
    "$WRITE_DELTA" \
    "$WRITE_KAPPA"

# =============================================================================
# Final
# =============================================================================

log "CONCLUÍDO"

echo "Repetições individuais:"
echo "  $RAW_DIR/read_rep*.csv"
echo "  $RAW_DIR/write_rep*.csv"
echo

echo "Agregados (mediana):"
echo "  $READ_AGGREGATED"
echo "  $WRITE_AGGREGATED"
echo

echo "Parâmetros USL:"
echo
echo "  READ"
echo "    Lambda = $READ_LAMBDA"
echo "    Delta  = $READ_DELTA"
echo "    Kappa  = $READ_KAPPA"
echo
echo "  WRITE"
echo "    Lambda = $WRITE_LAMBDA"
echo "    Delta  = $WRITE_DELTA"
echo "    Kappa  = $WRITE_KAPPA"
echo

echo "Gráficos:"
echo "  usl_read.png"
echo "  usl_write.png"
echo "  usl_throughput.png"
echo "  usl_transformed.png"