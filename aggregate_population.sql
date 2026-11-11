-- Both file paths are on the ClickHouse server.
-- The population table must contain resolution-8 H3 cells and integer counts.
-- Missing noise is assigned 0 dB. This is a placeholder, not zero energy.
-- Include all populated children of resolution-4 parents in the noise file.
-- The output file must not exist.

INSERT INTO FUNCTION file(
    'chungus/scratch/EEA-population-median-r4.arrow',
    'Arrow',
    'index_upper UInt32, index_lower UInt32, value Float32'
)
WITH
    noise AS
    (
        SELECT
            bitOr(bitShiftLeft(toUInt64(index_upper), 32), toUInt64(index_lower)) AS h3,
            value AS noise_db
        FROM file('chungus/scratch/EEA-r10-to-r8.arrow', 'Arrow')
    ),
    population AS
    (
        SELECT
            h3,
            h3ToParent(h3, 6) AS parent,
            toUInt64(population) AS weight
        FROM public_kontur_population_20231101
        WHERE population > 0
          AND parent IN (SELECT DISTINCT h3ToParent(h3, 6) FROM noise)
    )
SELECT
    toUInt32(bitShiftRight(p.parent, 32)) AS index_upper,
    toUInt32(bitAnd(p.parent, toUInt64(4294967295))) AS index_lower,
    toFloat32(quantileExactWeighted(0.5)(ifNull(n.noise_db, toFloat32(0)), p.weight)) AS value
FROM population AS p
LEFT JOIN noise AS n ON p.h3 = n.h3
GROUP BY p.parent
HAVING value > 0
ORDER BY p.parent
SETTINGS
    join_use_nulls = 1,
    output_format_arrow_compression_method = 'none',
    engine_file_truncate_on_insert = 1,
    engine_file_allow_create_multiple_files = 0;
