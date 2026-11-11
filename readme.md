# EEA noise

Aggregate EEA noise data to h3 res 6 using Kontur population data

## Data source

[Noise contours data reported under Environmental Noise Directive (END) 2022
(vector), Mar. 2026](https://sdi.eea.europa.eu/data/853e72e4-4642-47d1-8556-2cc231bd43e0).

The GeoPackages use EPSG:3035.

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
cells without contours contribute zero energy.

## Output

The combined output is `data/h3/EEA-r10-to-r8.arrow`.

| Column | Type | Content |
| --- | --- | --- |
| `index_upper` | UInt32 | Upper 32 bits of the H3 index |
| `index_lower` | UInt32 | Lower 32 bits of the H3 index |
| `value` | Float32 | Energy-mean combined Lden estimate in dB |

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
base cell at a time to limit memory use.

Progress is saved in `data/h3/eea-work/state.json`. Country logs and caches
are in `data/h3/eea-work/countries/`. Repeat the command to resume an
interrupted run. Completed caches are reused if the input files have not
changed. Do not start another main runner with the same work directory.

To use free CPU cores during a run, start extra workers:

```bash
python3 assist_dataset.py \
  data/eea_v_3035_1_k_noise-contours-end2022_p_2026_v01_r00 \
  --work-dir data/h3/eea-work --jobs 5
```

```bash
jaq '.status, (.countries | map(.status) | group_by(.) | map({status: .[0], count: length}))' \
  data/h3/eea-work/state.json
```

A failed country prevents publication of the combined output. Existing
source files and previous Arrow outputs are not changed.

## Population-weighted median

Run `aggregate_population.sql` on a ClickHouse server that has
`public_kontur_population_20231101`. 

## Tests

```bash
julia +1.10 --project=../geojson2h3 --threads=8 test_country.jl
julia +1.10 --project=../geojson2h3 test_dataset.jl
python3 test_aggregate_population.py
node test_h3mon.mjs data/h3/EEA-r10-to-r8.arrow
```
