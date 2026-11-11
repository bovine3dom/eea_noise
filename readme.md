# EEA noise

Create an EU-wide map of population-weighted noise at H3 resolution 8.
Join Kontur population data in ClickHouse next.

## Data source

[Noise contours data reported under Environmental Noise Directive (END) 2022
(vector), Mar. 2026](https://sdi.eea.europa.eu/data/853e72e4-4642-47d1-8556-2cc231bd43e0).

The GeoPackages use EPSG:3035. Select only layers that end in `_Lden`.
The importer checks the GeoPackage. It repairs geometries with
`ogr2ogr -makevalid` and transforms coordinates to EPSG:4326. Null geometries
do not contribute. The Rust helper uses `--polygon-only`: lines, points,
and empty polygon components have no area and do not contribute. Polygon
components in geometry collections are retained. The source GeoPackage is
not changed.

## Method

1. Sample noise polygons at resolution-10 H3 cell centres with
   `--containment center` in `~/projects/geojson2h3`.
2. Convert each 5 dB band to its midpoint: use 42.5 dB for `Lden4044`,
   47.5 dB for `Lden4549`, and so on. Use 37.5 dB for
   `LdenLowerThan40` and 77.5 dB for `LdenGreaterThan75`.
3. Skip identical reports within each source family. Retain the highest
   estimate per centre for roads, railways, airports, and industry. Do not
   add major-source and agglomeration reports from the same family.
4. Add energy contributions from the separate source families at each
   fine cell centre: `E_sample = sum(10^(L_source / 10))`.
5. Average energy over every fine child of each resolution-8 output cell,
   then convert back to dB:

   ```text
   value = 10 * log10(sum(E_sample) / N)
   ```

Use all 49 children in the denominator, or 41 for pentagon parents. Fine
cells without contours contribute zero energy. Do not divide only by the
number of samples with reported noise. Cells with no contribution are
omitted. Do not average dB values or take their geometric mean.

This is equal-weight sampling through the
[H3 logical hierarchy](https://h3geo.org/docs/highlights/indexing/), not exact
polygon-area weighting. Fine cells do not exactly tile the parent boundary.
The output has no band or quality-flag columns.

For noise addition, see the
[CCOHS guidance](https://www.ccohs.ca/oshanswers/phys_agents/noise_basic.html).

## Output

The combined output is `data/h3/EEA-r10-to-r8.arrow`. It is published only
after all 24 countries and the final H3-MON check succeed.

The existing country files are:

- `data/h3/CY-r10-to-r8.arrow`: Cyprus, 840 rows.
- `data/h3/AT-r10-to-r8.arrow`: Austria, 12,899 rows.

| Column | Type | Content |
| --- | --- | --- |
| `index_upper` | UInt32 | Upper 32 bits of the H3 index |
| `index_lower` | UInt32 | Lower 32 bits of the H3 index |
| `value` | Float32 | Energy-mean combined Lden estimate in dB |

All output cells have resolution 8. There are no additional columns or
dictionary encoding. `data/h3/CY-center.arrow` is the earlier single-centre
estimate. The files in `data/h3/CY/` are earlier maximum-overlap results.
Keep these files for comparison.

## Run

Install the dependencies and build the Rust helper as described in
[`geojson2h3/readme.md`](../geojson2h3/readme.md). Then run:

```bash
julia +1.10 --project=../geojson2h3 --threads=8 convert_country.jl \
  data/eea_v_3035_1_k_noise-contours-end2022_p_2026_v01_r00/CY.gpkg data/h3/CY-r10-to-r8.arrow
```

The importer pipes GeoJSON directly from GDAL to the Rust helper. Julia
reads only band keys and H3 cell lists; it does not parse geometry text.
Both pipeline exit codes are checked. The output is published only after
conversion succeeds. Existing files are not replaced.

## Entire dataset

Germany is supplied as `DE-gpkg.7z`. Extract `DE.gpkg` before the full run.
The runner checks the country list and file sizes against `data/download`.
It processes three countries at once, with two Julia threads per country.

```bash
python3 convert_dataset.py \
  data/eea_v_3035_1_k_noise-contours-end2022_p_2026_v01_r00 \
  data/h3/EEA-r10-to-r8.arrow --archive data/download \
  --work-dir data/h3/eea-work --jobs 3 --threads 2
```

Country caches retain resolution-10 source-family estimates. The final
merge takes the maximum per source family and fine cell across countries,
then adds source energies and averages to resolution 8. It does not
concatenate or average country-level dB values. This prevents duplicate
reports at borders from adding energy twice.

Caches have one record batch per H3 base cell. The merger processes one
base cell at a time to limit memory use. These caches are internal files,
not H3-MON input. The combined output has only the three columns above and
uses no compression.

Progress is saved in `data/h3/eea-work/state.json`. Country logs and caches
are in `data/h3/eea-work/countries/`. Repeat the command to resume an
interrupted run. Completed caches are reused if the input files have not
changed. Do not start another main runner with the same work directory.

The GDAL and Rust stages are mostly single-threaded. More Julia threads
do not make these stages run in parallel. To use free CPU cores during a
run, start five extra country workers for eight CPU cores:

```bash
python3 assist_dataset.py \
  data/eea_v_3035_1_k_noise-contours-end2022_p_2026_v01_r00 \
  --work-dir data/h3/eea-work --jobs 5
```

If you omit `--jobs`, the worker count is the available CPU count minus
that of the main runner. CPU use can fall when few countries remain.

The extra workers select pending countries, with small inputs first.
They check available memory against estimates from geometry sizes and
keep a 16 GiB reserve in that calculation. This is not a hard memory
limit. Countries that do not fit remain with the main runner. Logs are
in `data/h3/eea-work/helpers/`.

Country locks prevent duplicate work. Cache metadata identifies the
input and calculation method. The main runner reuses these caches when
it reaches the corresponding countries. Existing jobs are not restarted.

```bash
jaq '.status, (.countries | map(.status) | group_by(.) | map({status: .[0], count: length}))' \
  data/h3/eea-work/state.json
```

A failed country prevents publication of the combined output. Existing
source files and previous Arrow outputs are not changed.

## Scaling check

These measurements used the earlier batched JSON path, before direct
GDAL-to-Rust streaming. The input files were in the file-system cache.
Each run used eight Julia threads. Memory is resident set size (RSS), summed across the process tree.

| Country | Input Lden features | Elapsed time | Peak sampled tree RSS | Output size |
| --- | ---: | ---: | ---: | ---: |
| Cyprus | 155 | 74 s | 1.88 GiB | 10,850 bytes |
| Austria | 629,049 | 271 s | 2.56 GiB | 155,570 bytes |

The Austria road layer took 212 s to sample and convert. The railway
layer took 36 s. These two large layers processed about 4.5 MB of source
geometry per second. Their run times were roughly proportional to geometry
size. Do not estimate run time from country area alone.

The original per-feature process design was stopped during rail conversion
after 364 s. This was not a complete baseline run. Batched processing
produced a Cyprus file identical, byte for byte, to the previous output.

Results and per-layer timings are in `data/h3/AT-benchmark.json`,
`data/h3/CY-benchmark.json`, and their `.log` files. Memory was sampled
every 0.25 s. Shared pages can be counted more than once. Elapsed time
includes Julia startup.

The benchmark wrapper requires Python and `psutil`. Use new output paths
when you repeat a run:

```bash
python3 benchmark_country.py data/h3/AT-rerun-benchmark.json \
  julia +1.10 --project=../geojson2h3 --threads=8 convert_country.jl \
  data/eea_v_3035_1_k_noise-contours-end2022_p_2026_v01_r00/AT.gpkg data/h3/AT-rerun.arrow
```

## Tests

```bash
julia +1.10 --project=../geojson2h3 --threads=8 test_country.jl
julia +1.10 --project=../geojson2h3 test_dataset.jl
node test_h3mon.mjs data/h3/EEA-r10-to-r8.arrow
```

Importer tests cover energy averaging, complete child counts, pentagons,
duplicate reports, and producer failure.

The decoder test uses the installed dependencies in `~/projects/H3-MON`.
It checks the Arrow schema, index types, H3 resolution, and numeric values.
The H3-MON Arrow reader rejects record-batch compression.
