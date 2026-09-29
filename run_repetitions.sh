#!/bin/bash
set -euo pipefail

# =============================================================================
# run_repetitions.sh
#
# Corre a varredura completa de concorrência (stress_reads.sh + stress_writes.sh)
# REPETICOES vezes, guarda cada repetição em ficheiros separados dentro de
# raw_data/ (raw_data/read_rep<N>.dat / raw_data/write_rep<N>.dat), agrega
# tudo com aggregate_runs.py (mediana por nível de concorrência) e no final
# corre analyze_usl.sh sobre os dados agregados.
#
# Uso:
#   ./run_repetitions.sh <repeticoes> <duration> "<concurrency levels>"
#
# Exemplo (3 repetições, 30s por nível, varredura completa):
#   ./run_repetitions.sh 3 30s "1 2 4 8 16 32 64 128 200 240"
#
# Requisitos: os ficheiros seguintes têm de estar na mesma pasta que este
# script:
#   stress_reads.sh
#   stress_writes.sh
#   aggregate_runs.py
#   analyze_usl.sh   (versão corrigida, com nnls + avisos de confiabilidade)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

READ_SCRIPT="$SCRIPT_DIR/stress_reads.sh"
WRITE_SCRIPT="$SCRIPT_DIR/stress_writes.sh"
AGGREGATE_SCRIPT="$SCRIPT_DIR/aggregate_runs.py"
ANALYSIS_SCRIPT="$SCRIPT_DIR/analyze_usl.sh"
RAW_DIR="raw_data"

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

chmod +x "$READ_SCRIPT" "$WRITE_SCRIPT" "$ANALYSIS_SCRIPT"

log "CONFIGURAÇÃO"
echo "Repetições        : $REPS"
echo "Duração por nível : $DURATION"
echo "Níveis            : $CONCURRENCY_LEVELS"
echo "Pasta de trabalho : $SCRIPT_DIR"

cd "$SCRIPT_DIR"

# =============================================================================
# Preparar pasta de dados brutos e limpar repetições anteriores
# (evita misturar dados de execuções antigas)
# =============================================================================

log "A preparar $RAW_DIR/"
mkdir -p "$RAW_DIR"
rm -f "$RAW_DIR"/read_rep*.dat "$RAW_DIR"/write_rep*.dat
echo "Feito."

# =============================================================================
# Correr REPS repetições
# =============================================================================

for i in $(seq 1 "$REPS"); do
    log "REPETIÇÃO $i / $REPS — READ"
    "$READ_SCRIPT" "$DURATION" "$CONCURRENCY_LEVELS"

    [[ -f "read_stress_results.dat" ]] ||
        fail "READ da repetição $i não produziu read_stress_results.dat."

    mv "read_stress_results.dat" "$RAW_DIR/read_rep${i}.dat"
    echo "Guardado: $RAW_DIR/read_rep${i}.dat"

    log "REPETIÇÃO $i / $REPS — WRITE"
    "$WRITE_SCRIPT" "$DURATION" "$CONCURRENCY_LEVELS"

    [[ -f "write_stress_results.dat" ]] ||
        fail "WRITE da repetição $i não produziu write_stress_results.dat."

    mv "write_stress_results.dat" "$RAW_DIR/write_rep${i}.dat"
    echo "Guardado: $RAW_DIR/write_rep${i}.dat"
done

# =============================================================================
# Agregar (mediana por N) -> read_stress_results.dat / write_stress_results.dat
# =============================================================================

log "A AGREGAR REPETIÇÕES (mediana por N)"
python3 "$AGGREGATE_SCRIPT"

[[ -f "read_stress_results.dat" ]]  || fail "Agregação não produziu read_stress_results.dat."
[[ -f "write_stress_results.dat" ]] || fail "Agregação não produziu write_stress_results.dat."

# =============================================================================
# Análise USL sobre os dados agregados
# =============================================================================

log "ANÁLISE USL (dados agregados de $REPS repetições)"
"$ANALYSIS_SCRIPT" "read_stress_results.dat" "write_stress_results.dat"

log "CONCLUÍDO"
echo "Repetições individuais : $RAW_DIR/read_rep*.dat / $RAW_DIR/write_rep*.dat"
echo "Agregados (mediana)    : read_stress_results.dat / write_stress_results.dat"
echo "Relatório USL          : usl_analysis.txt"
echo "Fatores                : usl_factors.dat"
echo "Gráficos               : usl_read.png usl_write.png usl_throughput.png usl_transformed.png"
