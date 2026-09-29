import glob
import os
import statistics
import csv
from collections import defaultdict

# Pasta onde ficam os dados brutos de cada repetição
# (read_rep*.csv / write_rep*.csv).
#
# Os ficheiros agregados continuam a ser gravados na pasta principal:
#   read_stress_results.csv
#   write_stress_results.csv
#
# IMPORTANTE:
#   Os CSVs NÃO possuem cabeçalho.
#
# Formato:
#   N,Throughput
#
# Exemplo:
#   1,1234.56
#   2,2345.67
#   4,4521.89
#
RAW_DIR = "raw_data"


def aggregate(pattern, output):
    by_n = defaultdict(list)

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

    # =========================================================================
    # Ler os CSVs
    #
    # Não existe cabeçalho.
    # Coluna 0 = N
    # Coluna 1 = Throughput
    # =========================================================================

    for path in files:
        with open(path, newline="", encoding="utf-8") as f:
            reader = csv.reader(f)

            for line_number, row in enumerate(reader, start=1):

                # Ignorar linhas vazias
                if not row:
                    continue

                # Esperamos exatamente pelo menos duas colunas
                if len(row) < 2:
                    print(
                        f"AVISO: linha {line_number} inválida em {path}: {row}"
                    )
                    continue

                try:
                    n = float(row[0])
                    throughput = float(row[1])
                except (ValueError, TypeError):
                    print(
                        f"AVISO: linha {line_number} inválida em {path}: {row}"
                    )
                    continue

                if throughput <= 0:
                    print(
                        f"AVISO: throughput inválido em {path}, "
                        f"N={n}: {throughput}"
                    )
                    continue

                by_n[n].append(throughput)

    # =========================================================================
    # Verificar se encontrámos dados
    # =========================================================================

    if not by_n:
        print(
            f"AVISO: nenhum dado válido encontrado nos ficheiros "
            f"correspondentes a '{pattern}'."
        )
        return

    # =========================================================================
    # Escrever CSV agregado
    #
    # Sem cabeçalho.
    # =========================================================================

    with open(output, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)

        for n in sorted(by_n):
            throughput_median = statistics.median(by_n[n])

            writer.writerow([
                int(n) if n.is_integer() else n,
                f"{throughput_median:.2f}"
            ])

    print(f"Gravado: {output}\n")


aggregate(
    "read_rep*.csv",
    "read_stress_results.csv"
)

aggregate(
    "write_rep*.csv",
    "write_stress_results.csv"
)