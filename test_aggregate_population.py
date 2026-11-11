import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent


def sibling(cell, digit):
    return (cell & ~(7 << 21)) | (digit << 21)


def parent4(cell):
    return (cell & ~(15 << 52)) | (4 << 52) | ((1 << 33) - 1)


def main():
    a = int('881fb46625fffff', 16)
    b = 612489638539427839
    outside = int('8808000001fffff', 16)
    unpopulated = (b & ~(127 << 45)) | (1 << 45)
    noise = [(sibling(a, 0), 60), (sibling(a, 2), 100),
             (sibling(b, 0), 50), (sibling(b, 1), 70), (unpopulated, 80)]
    population = [(sibling(a, 0), 40), (sibling(a, 1), 60), (sibling(a, 2), 0),
                  (sibling(b, 0), 25), (sibling(b, 1), 55), (sibling(b, 2), 20),
                  (outside, 1000), (unpopulated, 0)]
    with TemporaryDirectory(prefix='eea-population-') as temporary:
        directory = Path(temporary)
        source = directory / 'noise.arrow'
        output = directory / 'median.arrow'
        script = (ROOT / 'aggregate_population.sql').read_text().replace(
            'chungus/scratch/EEA-r10-to-r8.arrow', str(source)).replace(
            'chungus/scratch/EEA-population-median-r4.arrow', str(output))
        people = ', '.join(f'({cell}, {weight})' for cell, weight in population)
        levels = ', '.join(f'({cell}, {value})' for cell, value in noise)
        setup = f"""
CREATE TABLE public_kontur_population_20231101 (h3 UInt64, population UInt64) ENGINE = Memory;
INSERT INTO public_kontur_population_20231101 VALUES {people};
"""
        fixture = f"""
INSERT INTO FUNCTION file('{source}', 'Arrow')
SELECT toUInt32(bitShiftRight(h3, 32)) AS index_upper,
       toUInt32(bitAnd(h3, toUInt64(4294967295))) AS index_lower, value
FROM values('h3 UInt64, value Float32', {levels});
"""
        inspect = f"""
SELECT bitOr(bitShiftLeft(toUInt64(index_upper), 32), toUInt64(index_lower)) AS h3, value
FROM file('{output}', 'Arrow') FORMAT JSONEachRow;
"""
        query_file = directory / 'test.sql'
        query_file.write_text(setup + fixture + script + inspect)
        result = subprocess.run(['clickhouse', 'local', '--multiquery', '--queries-file', str(query_file)],
                                check=True, capture_output=True, text=True)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        assert {int(row['h3']): row['value'] for row in rows} == {parent4(a): 0, parent4(b): 70}
        subprocess.run(['node', str(ROOT / 'test_h3mon.mjs'), str(output), '4'], check=True)
        original = output.read_bytes()
        query_file.write_text(setup + script)
        repeated = subprocess.run(['clickhouse', 'local', '--multiquery', '--queries-file', str(query_file)],
                                  capture_output=True, text=True)
        assert repeated.returncode != 0, 'The existing output must not be replaced or appended to'
        assert output.read_bytes() == original
        print('Population median tests passed: zero fill, weights, scope, empty cells, and output preservation')


if __name__ == '__main__':
    main()
