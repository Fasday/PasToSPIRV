"""Optional wall-clock CLI benchmark. Includes startup, source I/O and output I/O.
Not a GPU throughput benchmark and not a comparison with another compiler.
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time


def main(iterations):
    root = Path(__file__).resolve().parents[1]
    compiler = root / 'build/bin/PasToSPIRV.exe'
    output = root / 'build/benchmark'
    output.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([str(compiler), '--version'], encoding='utf-8').strip()
    results = []
    for name in ('empty', 'layout_records', 'shared_reduce', 'storage_image', 'modules_compute'):
        for option in ('-O0', '-O1'):
            target = output / f'{name}-{option[1:]}.spv'
            args = [str(compiler), 'compile', str(root / f'examples/{name}.pas'), '-o', str(target), option]
            if name == 'modules_compute': args.extend(['-I', str(root / 'examples/modules')])
            subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            timings = []
            for _ in range(iterations):
                start = time.perf_counter()
                subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                timings.append((time.perf_counter() - start) * 1000)
            results.append({'source': name, 'option': option, 'iterations': iterations,
                            'median_ms': statistics.median(timings), 'min_ms': min(timings),
                            'spirv_bytes': target.stat().st_size})
    report = {'compiler': version, 'measurement': 'wall-clock CLI startup + compilation + I/O; warm filesystem cache',
              'gpu_throughput': 'not measured', 'results': results}
    (output / 'results.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iterations', type=int, default=10)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100: parser.error('iterations must be in 1..100')
    main(args.iterations)
