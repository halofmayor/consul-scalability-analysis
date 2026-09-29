#!/bin/bash
set -euo pipefail

# =============================================================================
# Configuração dos scripts
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

READ_SCRIPT="$SCRIPT_DIR/stress_reads.sh"
WRITE_SCRIPT="$SCRIPT_DIR/stress_writes.sh"
ANALYSIS_SCRIPT="$SCRIPT_DIR/analyze_usl.sh"

READ_RESULTS="$SCRIPT_DIR/read_stress_results.dat"
WRITE_RESULTS="$SCRIPT_DIR/write_stress_results.dat"

# =============================================================================
# Uso
# =============================================================================

usage() {
    echo "Uso:"
    echo "  $0 <duration> \"<concurrency levels>\""
    echo
    echo "Exemplo:"
    echo "  $0 30s \"1 2 4 8 16 32 64 128 200 240\""
    echo
}

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

DURATION="$1"
CONCURRENCY_LEVELS="$2"

# =============================================================================
# Funções auxiliares
# =============================================================================

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
# Checks básicos dos parâmetros
# =============================================================================

[[ -n "$DURATION" ]] || fail "A duração não pode estar vazia."

[[ -n "$CONCURRENCY_LEVELS" ]] ||
    fail "Os níveis de concorrência não podem estar vazios."

# Verificação simples da duração:
# exemplos válidos: 10s, 30s, 1m, 500ms
if ! [[ "$DURATION" =~ ^[0-9]+(ms|s|m|h)$ ]]; then
    fail "Duração inválida: '$DURATION'. Exemplos: 10s, 30s, 1m."
fi

# Verificar que os níveis são números positivos
for N in $CONCURRENCY_LEVELS; do
    if ! [[ "$N" =~ ^[0-9]+$ ]]; then
        fail "Nível de concorrência inválido: '$N'."
    fi

    if [[ "$N" -lt 1 ]]; then
        fail "Os níveis de concorrência devem ser >= 1."
    fi
done

# =============================================================================
# Checks dos ficheiros/scripts
# =============================================================================

log "A verificar ficheiros do benchmark"

[[ -f "$READ_SCRIPT" ]] ||
    fail "Script de READ não encontrado: $READ_SCRIPT"

[[ -f "$WRITE_SCRIPT" ]] ||
    fail "Script de WRITE não encontrado: $WRITE_SCRIPT"

[[ -f "$ANALYSIS_SCRIPT" ]] ||
    fail "Script de análise não encontrado: $ANALYSIS_SCRIPT"

chmod +x "$READ_SCRIPT"
chmod +x "$WRITE_SCRIPT"
chmod +x "$ANALYSIS_SCRIPT"

echo "  READ script   : $READ_SCRIPT"
echo "  WRITE script  : $WRITE_SCRIPT"
echo "  Analysis      : $ANALYSIS_SCRIPT"

# =============================================================================
# Checks do ambiente
# =============================================================================

log "A verificar ambiente"

# -----------------------------------------------------------------------------
# Bash
# -----------------------------------------------------------------------------

if ! command -v bash >/dev/null 2>&1; then
    fail "bash não está instalado."
fi

echo "  [OK] bash"

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    fail "Docker não está instalado."
fi

echo "  [OK] docker"

if ! docker info >/dev/null 2>&1; then
    fail "O Docker está instalado, mas o daemon não está acessível."
fi

echo "  [OK] Docker daemon"

# -----------------------------------------------------------------------------
# curl
# -----------------------------------------------------------------------------

if ! command -v curl >/dev/null 2>&1; then
    fail "curl não está instalado."
fi

echo "  [OK] curl"

# -----------------------------------------------------------------------------
# Python
# -----------------------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 não está instalado."
fi

echo "  [OK] python3"

# -----------------------------------------------------------------------------
# NumPy
# -----------------------------------------------------------------------------

if ! python3 -c "import numpy" >/dev/null 2>&1; then
    fail "Python3 está instalado, mas o NumPy não está disponível."
fi

echo "  [OK] Python NumPy"

# -----------------------------------------------------------------------------
# Gnuplot
# -----------------------------------------------------------------------------

if ! command -v gnuplot >/dev/null 2>&1; then
    fail "gnuplot não está instalado."
fi

echo "  [OK] gnuplot"

# =============================================================================
# Verificar acesso às imagens Docker
# =============================================================================

log "A verificar imagens Docker"

CONSUL_IMAGE="hashicorp/consul:latest"
K6_IMAGE="grafana/k6:latest"

# -----------------------------------------------------------------------------
# Consul
#
# Se a imagem não existir localmente, fazemos pull.
# -----------------------------------------------------------------------------

if ! docker image inspect "$CONSUL_IMAGE" >/dev/null 2>&1; then
    echo "Imagem $CONSUL_IMAGE não encontrada localmente."
    echo "A fazer pull..."
    docker pull "$CONSUL_IMAGE"
fi

echo "  [OK] $CONSUL_IMAGE"

# -----------------------------------------------------------------------------
# k6
# -----------------------------------------------------------------------------

if ! docker image inspect "$K6_IMAGE" >/dev/null 2>&1; then
    echo "Imagem $K6_IMAGE não encontrada localmente."
    echo "A fazer pull..."
    docker pull "$K6_IMAGE"
fi

echo "  [OK] $K6_IMAGE"

# =============================================================================
# Mostrar configuração
# =============================================================================

log "Configuração do benchmark"

echo "Duração por nível : $DURATION"
echo "Níveis            : $CONCURRENCY_LEVELS"
echo
echo "READ output       : $READ_RESULTS"
echo "WRITE output      : $WRITE_RESULTS"

# =============================================================================
# Limpar resultados anteriores
#
# Isto evita que uma análise posterior utilize dados de uma execução anterior
# caso um dos experimentos falhe a meio.
# =============================================================================

log "A limpar resultados anteriores"

rm -f "$READ_RESULTS"
rm -f "$WRITE_RESULTS"

echo "Resultados anteriores removidos."

# =============================================================================
# Experimento de READ
# =============================================================================

log "EXPERIMENTO 1 — READ SCALABILITY"

echo "A executar:"
echo "  $READ_SCRIPT $DURATION \"$CONCURRENCY_LEVELS\""
echo

"$READ_SCRIPT" "$DURATION" "$CONCURRENCY_LEVELS"

echo
echo "Experimento de READ concluído."
echo "Resultado: $READ_RESULTS"

# =============================================================================
# Confirmar que o READ produziu resultado
# =============================================================================

if [[ ! -f "$READ_RESULTS" ]]; then
    fail "O experimento de READ terminou sem produzir $READ_RESULTS."
fi

echo "  [OK] $READ_RESULTS"

# =============================================================================
# Experimento de WRITE
# =============================================================================

log "EXPERIMENTO 2 — WRITE SCALABILITY"

echo "A executar:"
echo "  $WRITE_SCRIPT $DURATION \"$CONCURRENCY_LEVELS\""
echo

"$WRITE_SCRIPT" "$DURATION" "$CONCURRENCY_LEVELS"

echo
echo "Experimento de WRITE concluído."
echo "Resultado: $WRITE_RESULTS"

# =============================================================================
# Confirmar que o WRITE produziu resultado
# =============================================================================

if [[ ! -f "$WRITE_RESULTS" ]]; then
    fail "O experimento de WRITE terminou sem produzir $WRITE_RESULTS."
fi

echo "  [OK] $WRITE_RESULTS"

# =============================================================================
# Análise
# =============================================================================

log "ANÁLISE USL"

echo "A executar:"
echo "  $ANALYSIS_SCRIPT"
echo

"$ANALYSIS_SCRIPT" "$READ_RESULTS" "$WRITE_RESULTS"

# =============================================================================
# Final
# =============================================================================

log "BENCHMARK CONCLUÍDO"

echo "Ficheiros gerados:"
echo
echo "  Dados:"
echo "    $READ_RESULTS"
echo "    $WRITE_RESULTS"
echo
echo "  Análise:"
echo "    $SCRIPT_DIR/usl_factors.dat"
echo "    $SCRIPT_DIR/usl_analysis.txt"
echo
echo "  Gráficos:"
echo "    $SCRIPT_DIR/usl_read.png"
echo "    $SCRIPT_DIR/usl_write.png"
echo "    $SCRIPT_DIR/usl_throughput.png"
echo "    $SCRIPT_DIR/usl_transformed.png"
echo
echo "Todos os passos foram concluídos."