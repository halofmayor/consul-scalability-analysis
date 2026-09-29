import glob
import os
import statistics
from collections import defaultdict

# Pasta onde ficam os dados brutos de cada repetição (read_rep*.dat / write_rep*.dat).
# Os ficheiros agregados (read_stress_results.dat / write_stress_results.dat)
# continuam a ser gravados na pasta principal, porque é aí que o analyze_usl.sh
# e o run_benchmark.sh esperam encontrá-los.
RAW_DIR = "raw_data"


def aggregate(pattern, output):
    by_n = defaultdict(list)
    header = None

    # Procura primeiro em raw_data/, e só usa a pasta principal como
    # alternativa (compatibilidade com pastas que ainda não foram
    # reorganizadas).
    search_path = os.path.join(RAW_DIR, pattern)
    files = sorted(glob.glob(search_path))

    if not files:
        files = sorted(glob.glob(pattern))
        if files:
            print(
                f"AVISO: '{pattern}' não encontrado em '{RAW_DIR}/', "
                f"a usar os ficheiros da pasta atual em vez disso."
            )

    if not files:
        print(
            f"AVISO: nenhum ficheiro encontrado para '{pattern}' "
            f"(procurei em '{RAW_DIR}/' e na pasta atual)."
        )
        return

    print(f"A agregar {len(files)} ficheiro(s) que batem com '{pattern}':")
    for path in files:
        print(f"  - {path}")

    for path in files:
        with open(path) as f:
            for line in f:
                if line.startswith("#"):
                    header = line
                    continue
                parts = line.split()
                if len(parts) < 7:
                    continue
                n = float(parts[0])
                by_n[n].append([float(x) for x in parts[1:7]])

    with open(output, "w") as f:
        f.write(header or "# N Throughput Avg Med P90 P95 Max\n")
        for n in sorted(by_n):
            reps = len(by_n[n])
            cols = list(zip(*by_n[n]))
            medians = [statistics.median(c) for c in cols]
            f.write(
                f"{n:<6.0f} " + " ".join(f"{v:<14.2f}" for v in medians)
                + f"  # {reps} repeticoes\n"
            )

    print(f"Gravado: {output}\n")


aggregate("read_rep*.dat", "read_stress_results.dat")
aggregate("write_rep*.dat", "write_stress_results.dat")
