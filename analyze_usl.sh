#!/bin/bash
set -euo pipefail

# =============================================================================
# USL analysis
#
# Input:
#   read_stress_results.dat
#   write_stress_results.dat
#
# Usage:
#   ./analyze_usl.sh
#
# Optional:
#   ./analyze_usl.sh my_reads.dat my_writes.dat
#
# Requirements:
#   - bash
#   - python3
#   - python3-numpy
#   - gnuplot
# =============================================================================

export LC_ALL=C

READ_FILE="${1:-read_stress_results.dat}"
WRITE_FILE="${2:-write_stress_results.dat}"

FACTORS_FILE="usl_factors.dat"
REPORT_FILE="usl_analysis.txt"

THROUGHPUT_PLOT="usl_throughput.png"
TRANSFORMED_PLOT="usl_transformed.png"
READ_PLOT="usl_read.png"
WRITE_PLOT="usl_write.png"

# =============================================================================
# Verificar dependências
# =============================================================================

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERRO: python3 não encontrado." >&2
    exit 1
fi

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

echo "================================================================================"
echo "Universal Scalability Law Analysis"
echo "================================================================================"
echo
echo "READ  : $READ_FILE"
echo "WRITE : $WRITE_FILE"
echo

# =============================================================================
# Python:
#   - lê os .dat
#   - encontra X(1) = gamma
#   - estima sigma e kappa
#   - calcula R²
#   - cria ficheiro de parâmetros para o gnuplot
#   - cria relatório textual
# =============================================================================

PARAM_FILE="$(mktemp)"
trap 'rm -f "$PARAM_FILE"' EXIT

python3 - "$READ_FILE" "$WRITE_FILE" "$PARAM_FILE" "$FACTORS_FILE" "$REPORT_FILE" << 'PY'
import sys
import math
from pathlib import Path

try:
    import numpy as np
except ImportError:
    print("ERRO: numpy não está instalado.", file=sys.stderr)
    print("Instale-o com: python3 -m pip install numpy", file=sys.stderr)
    sys.exit(1)

read_file = Path(sys.argv[1])
write_file = Path(sys.argv[2])
param_file = Path(sys.argv[3])
factors_file = Path(sys.argv[4])
report_file = Path(sys.argv[5])


# =============================================================================
# Ler ficheiro .dat
# =============================================================================

def load_data(path):
    rows = []

    with path.open("r", encoding="utf-8") as f:
        for line_number, line in enumerate(f, start=1):
            line = line.strip()

            if not line:
                continue

            if line.startswith("#"):
                continue

            parts = line.split()

            if len(parts) < 7:
                continue

            try:
                n = float(parts[0])
                throughput = float(parts[1])
                avg_latency = float(parts[2])
                med_latency = float(parts[3])
                p90 = float(parts[4])
                p95 = float(parts[5])
                max_latency = float(parts[6])
            except ValueError:
                print(
                    f"AVISO: linha {line_number} ignorada em {path}: {line}",
                    file=sys.stderr
                )
                continue

            if throughput <= 0:
                raise ValueError(
                    f"{path}: throughput inválido em N={n}: {throughput}"
                )

            rows.append({
                "N": n,
                "X": throughput,
                "avg": avg_latency,
                "med": med_latency,
                "p90": p90,
                "p95": p95,
                "max": max_latency,
            })

    if not rows:
        raise ValueError(f"{path}: nenhum dado válido encontrado.")

    rows.sort(key=lambda r: r["N"])

    return rows


# =============================================================================
# Ajustar USL
#
# USL:
#
# X(N) = gamma*N /
#        [1 + sigma*(N-1) + kappa*N*(N-1)]
#
# Para N=1:
#
# gamma = X(1)
#
# Para N > 1:
#
# gamma*N/X(N) - 1
#     = sigma*(N-1) + kappa*N*(N-1)
#
# Portanto fazemos uma regressão:
#
# y = sigma*x1 + kappa*x2
#
# onde:
#
# x1 = N - 1
# x2 = N*(N-1)
# =============================================================================

def fit_usl(rows):
    baseline = None

    for row in rows:
        if abs(row["N"] - 1.0) < 1e-12:
            baseline = row
            break

    if baseline is None:
        raise ValueError(
            "O ficheiro não contém N=1. "
            "É necessário N=1 para determinar gamma diretamente."
        )

    gamma = baseline["X"]

    fit_rows = [r for r in rows if abs(r["N"] - 1.0) >= 1e-12]

    if len(fit_rows) < 2:
        raise ValueError(
            "São necessários pelo menos dois níveis além de N=1 "
            "para estimar sigma e kappa."
        )

    A = []
    b = []

    for row in fit_rows:
        n = row["N"]
        x = row["X"]

        x1 = n - 1.0
        x2 = n * (n - 1.0)

        target = gamma * n / x - 1.0

        A.append([x1, x2])
        b.append(target)

    A = np.asarray(A, dtype=float)
    b = np.asarray(b, dtype=float)

    coefficients, residuals, rank, singular_values = np.linalg.lstsq(
        A, b, rcond=None
    )

    sigma = float(coefficients[0])
    kappa = float(coefficients[1])

    # -------------------------------------------------------------------------
    # Predictions
    # -------------------------------------------------------------------------

    actual_x = np.asarray([r["X"] for r in rows], dtype=float)
    predicted_x = []

    for row in rows:
        n = row["N"]

        denominator = (
            1.0
            + sigma * (n - 1.0)
            + kappa * n * (n - 1.0)
        )

        predicted = gamma * n / denominator
        predicted_x.append(predicted)

    predicted_x = np.asarray(predicted_x)

    # -------------------------------------------------------------------------
    # R² no espaço de throughput
    # -------------------------------------------------------------------------

    ss_res = float(np.sum((actual_x - predicted_x) ** 2))
    ss_tot = float(np.sum((actual_x - np.mean(actual_x)) ** 2))

    if ss_tot > 0:
        r2_throughput = 1.0 - ss_res / ss_tot
    else:
        r2_throughput = float("nan")

    # -------------------------------------------------------------------------
    # R² no espaço transformado
    # -------------------------------------------------------------------------

    actual_y = []
    predicted_y = []

    for row in rows:
        n = row["N"]

        actual_y.append(n / row["X"])

        predicted_y.append(
            (
                1.0
                + sigma * (n - 1.0)
                + kappa * n * (n - 1.0)
            ) / gamma
        )

    actual_y = np.asarray(actual_y)
    predicted_y = np.asarray(predicted_y)

    y_ss_res = float(np.sum((actual_y - predicted_y) ** 2))
    y_ss_tot = float(np.sum((actual_y - np.mean(actual_y)) ** 2))

    if y_ss_tot > 0:
        r2_transformed = 1.0 - y_ss_res / y_ss_tot
    else:
        r2_transformed = float("nan")

    # -------------------------------------------------------------------------
    # Peak da curva USL
    #
    # Não é necessário para o cálculo dos fatores, mas é útil para análise.
    #
    # dX/dN = 0 leva a uma expressão para o N no qual a curva atinge o máximo.
    #
    # Aqui simplesmente procuramos numericamente uma boa aproximação.
    # -------------------------------------------------------------------------

    max_n = max(r["N"] for r in rows)
    search_max = max(1000.0, max_n * 10.0)

    grid = np.linspace(1.0, search_max, 10000)

    values = (
        gamma * grid
        /
        (
            1.0
            + sigma * (grid - 1.0)
            + kappa * grid * (grid - 1.0)
        )
    )

    peak_index = int(np.argmax(values))

    n_peak_estimate = float(grid[peak_index])
    x_peak_estimate = float(values[peak_index])

    return {
        "gamma": gamma,
        "sigma": sigma,
        "kappa": kappa,
        "r2_throughput": r2_throughput,
        "r2_transformed": r2_transformed,
        "n_peak": n_peak_estimate,
        "x_peak": x_peak_estimate,
        "rows": rows,
        "rank": rank,
    }


# =============================================================================
# Executar ambos os ajustes
# =============================================================================

read_result = fit_usl(load_data(read_file))
write_result = fit_usl(load_data(write_file))


# =============================================================================
# Ficheiro de parâmetros para o gnuplot
# =============================================================================

with param_file.open("w", encoding="utf-8") as f:
    f.write(f"READ_GAMMA={read_result['gamma']:.15g}\n")
    f.write(f"READ_SIGMA={read_result['sigma']:.15g}\n")
    f.write(f"READ_KAPPA={read_result['kappa']:.15g}\n")
    f.write(f"READ_N_PEAK={read_result['n_peak']:.15g}\n")
    f.write(f"READ_X_PEAK={read_result['x_peak']:.15g}\n")

    f.write(f"WRITE_GAMMA={write_result['gamma']:.15g}\n")
    f.write(f"WRITE_SIGMA={write_result['sigma']:.15g}\n")
    f.write(f"WRITE_KAPPA={write_result['kappa']:.15g}\n")
    f.write(f"WRITE_N_PEAK={write_result['n_peak']:.15g}\n")
    f.write(f"WRITE_X_PEAK={write_result['x_peak']:.15g}\n")

    max_n = max(
        max(r["N"] for r in read_result["rows"]),
        max(r["N"] for r in write_result["rows"]),
    )

    f.write(f"N_MAX={max_n:.15g}\n")


# =============================================================================
# Tabela simples para futura utilização
# =============================================================================

with factors_file.open("w", encoding="utf-8") as f:
    f.write(
        "# workload gamma sigma kappa "
        "R2_throughput R2_transformed N_peak X_peak\n"
    )

    f.write(
        "read "
        f"{read_result['gamma']:.10g} "
        f"{read_result['sigma']:.10g} "
        f"{read_result['kappa']:.10g} "
        f"{read_result['r2_throughput']:.10g} "
        f"{read_result['r2_transformed']:.10g} "
        f"{read_result['n_peak']:.10g} "
        f"{read_result['x_peak']:.10g}\n"
    )

    f.write(
        "write "
        f"{write_result['gamma']:.10g} "
        f"{write_result['sigma']:.10g} "
        f"{write_result['kappa']:.10g} "
        f"{write_result['r2_throughput']:.10g} "
        f"{write_result['r2_transformed']:.10g} "
        f"{write_result['n_peak']:.10g} "
        f"{write_result['x_peak']:.10g}\n"
    )


# =============================================================================
# Relatório
# =============================================================================

def write_result_block(name, result, f):
    f.write(f"{name.upper()} WORKLOAD\n")
    f.write("-" * 72 + "\n")
    f.write(f"gamma  = {result['gamma']:.8f} req/s\n")
    f.write(f"sigma  = {result['sigma']:.8f}\n")
    f.write(f"kappa  = {result['kappa']:.8f}\n")
    f.write(f"R² (throughput) = {result['r2_throughput']:.8f}\n")
    f.write(f"R² (N/X)        = {result['r2_transformed']:.8f}\n")
    f.write(f"Estimated peak N = {result['n_peak']:.4f}\n")
    f.write(f"Estimated peak X = {result['x_peak']:.4f} req/s\n")
    f.write("\n")


with report_file.open("w", encoding="utf-8") as f:
    f.write("Universal Scalability Law Analysis\n")
    f.write("=" * 72 + "\n\n")

    f.write("Model:\n")
    f.write(
        "X(N) = gamma*N / "
        "[1 + sigma*(N-1) + kappa*N*(N-1)]\n\n"
    )

    f.write("Parameter identification:\n")
    f.write("gamma = X(1)\n")
    f.write(
        "gamma*N/X(N) - 1 = "
        "sigma*(N-1) + kappa*N*(N-1)\n\n"
    )

    write_result_block("read", read_result, f)
    write_result_block("write", write_result, f)

print("Análise matemática concluída.")
print()
print("READ:")
print(f"  gamma = {read_result['gamma']:.6f}")
print(f"  sigma = {read_result['sigma']:.6f}")
print(f"  kappa = {read_result['kappa']:.6f}")
print(f"  R²    = {read_result['r2_throughput']:.6f}")
print()
print("WRITE:")
print(f"  gamma = {write_result['gamma']:.6f}")
print(f"  sigma = {write_result['sigma']:.6f}")
print(f"  kappa = {write_result['kappa']:.6f}")
print(f"  R²    = {write_result['r2_throughput']:.6f}")
PY

# =============================================================================
# Carregar parâmetros
# =============================================================================

# shellcheck disable=SC1090
source "$PARAM_FILE"

# =============================================================================
# Mostrar resultados
# =============================================================================

echo
echo "================================================================================"
echo "Fatores obtidos"
echo "================================================================================"
echo

printf "%-10s %-14s %-14s %-14s %-14s\n" \
    "Workload" "gamma" "sigma" "kappa" "R²"

printf "%-10s %-14.6f %-14.6f %-14.6f %-14.6f\n" \
    "READ" \
    "$READ_GAMMA" \
    "$READ_SIGMA" \
    "$READ_KAPPA" \
    "$(awk '/^read / {print $5}' "$FACTORS_FILE")"

printf "%-10s %-14.6f %-14.6f %-14.6f %-14.6f\n" \
    "WRITE" \
    "$WRITE_GAMMA" \
    "$WRITE_SIGMA" \
    "$WRITE_KAPPA" \
    "$(awk '/^write / {print $5}' "$FACTORS_FILE")"

echo
echo "Relatório: $REPORT_FILE"
echo "Tabela   : $FACTORS_FILE"

# =============================================================================
# Gnuplot
# =============================================================================

GNUPLOT_SCRIPT="$(mktemp)"
trap 'rm -f "$PARAM_FILE" "$GNUPLOT_SCRIPT"' EXIT

cat > "$GNUPLOT_SCRIPT" << EOF

set terminal pngcairo size 1200,700 enhanced font "Arial,11"

set grid back
set border linewidth 1.2

# =============================================================================
# Funções USL
# =============================================================================

read_usl(x) = (${READ_GAMMA} * x) / \
              (1.0 + ${READ_SIGMA} * (x - 1.0) \
                    + ${READ_KAPPA} * x * (x - 1.0))

write_usl(x) = (${WRITE_GAMMA} * x) / \
               (1.0 + ${WRITE_SIGMA} * (x - 1.0) \
                     + ${WRITE_KAPPA} * x * (x - 1.0))

read_transformed(x) = \
    (1.0 \
     + ${READ_SIGMA} * (x - 1.0) \
     + ${READ_KAPPA} * x * (x - 1.0)) / ${READ_GAMMA}

write_transformed(x) = \
    (1.0 \
     + ${WRITE_SIGMA} * (x - 1.0) \
     + ${WRITE_KAPPA} * x * (x - 1.0)) / ${WRITE_GAMMA}

set xrange [0:${N_MAX} * 1.05]

# =============================================================================
# 1. Read throughput + USL
# =============================================================================

set output "${READ_PLOT}"

set title "Consul READ scalability - USL fit"
set xlabel "Concurrency / VUs (N)"
set ylabel "Throughput (req/s)"

set key top left box opaque

plot \
    "${READ_FILE}" using 1:2 \
        with points pt 7 ps 1.4 \
        title "Measured READ", \
    read_usl(x) \
        with lines lw 2.5 \
        title sprintf("USL: gamma=%.2f, sigma=%.5f, kappa=%.5f", \
                      ${READ_GAMMA}, ${READ_SIGMA}, ${READ_KAPPA})

# =============================================================================
# 2. Write throughput + USL
# =============================================================================

set output "${WRITE_PLOT}"

set title "Consul WRITE scalability - USL fit"
set xlabel "Concurrency / VUs (N)"
set ylabel "Throughput (req/s)"

plot \
    "${WRITE_FILE}" using 1:2 \
        with points pt 7 ps 1.4 \
        title "Measured WRITE", \
    write_usl(x) \
        with lines lw 2.5 \
        title sprintf("USL: gamma=%.2f, sigma=%.5f, kappa=%.5f", \
                      ${WRITE_GAMMA}, ${WRITE_SIGMA}, ${WRITE_KAPPA})

# =============================================================================
# 3. READ + WRITE comparison
# =============================================================================

set output "${THROUGHPUT_PLOT}"

set title "Consul scalability - READ vs WRITE"
set xlabel "Concurrency / VUs (N)"
set ylabel "Throughput (req/s)"

plot \
    "${READ_FILE}" using 1:2 \
        with points pt 7 ps 1.3 \
        title "Measured READ", \
    read_usl(x) \
        with lines lw 2 \
        title "READ USL", \
    "${WRITE_FILE}" using 1:2 \
        with points pt 5 ps 1.3 \
        title "Measured WRITE", \
    write_usl(x) \
        with lines lw 2 \
        title "WRITE USL"

# =============================================================================
# 4. Transformação N/X(N)
# =============================================================================

set output "${TRANSFORMED_PLOT}"

set title "USL parameter identification: N / X(N)"
set xlabel "Concurrency / VUs (N)"
set ylabel "N / Throughput (s)"

plot \
    "${READ_FILE}" using 1:(\$1/\$2) \
        with points pt 7 ps 1.3 \
        title "READ measured", \
    read_transformed(x) \
        with lines lw 2 \
        title "READ fitted", \
    "${WRITE_FILE}" using 1:(\$1/\$2) \
        with points pt 5 ps 1.3 \
        title "WRITE measured", \
    write_transformed(x) \
        with lines lw 2 \
        title "WRITE fitted"

EOF

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