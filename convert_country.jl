const CONVERTER = normpath(joinpath(@__DIR__, "..", "geojson2h3"))
include(joinpath(CONVERTER, "geojson2h3.jl"))

const BANDS = ["LdenLowerThan40", "Lden4044", "Lden4549", "Lden5054",
               "Lden5559", "Lden6064", "Lden6569", "Lden7074", "LdenGreaterThan75"]
const BAND_LEVELS = Dict(band => 37.5 + 5 * (i - 1) for (i, band) in enumerate(BANDS))
const SAMPLE_RESOLUTION = 10
const OUTPUT_RESOLUTION = 8
const PARENT_UNUSED = (UInt64(1) << (3 * (15 - OUTPUT_RESOLUTION))) - 1
const SOURCE_FAMILIES = Dict(
    "airportsInAgglomeration" => "airports", "majorAirportsIncludingAgglomeration" => "airports",
    "roadsInAgglomeration" => "roads", "majorRoadsIncludingAgglomeration" => "roads",
    "railwaysInAgglomeration" => "railways", "majorRailwaysIncludingAgglomeration" => "railways",
    "industryInAgglomeration" => "industry")

const FAMILY_IDS = Dict("airports" => 0x01, "industry" => 0x02, "railways" => 0x03, "roads" => 0x04)
const FINE_METADATA = Dict("model" => "r10-family-max-v1", "resolution" => string(SAMPLE_RESOLUTION),
    "families" => "airports,industry,railways,roads", "band_levels" => join((BAND_LEVELS[band] for band in BANDS), ','))

base_cell(cell) = (cell >> 45) & 0x7f

metadata_matches(actual, expected) = actual !== nothing &&
    all(get(actual, key, nothing) == value for (key, value) in expected)

function input_metadata(gpkg)
    info = stat(gpkg)
    return Dict("input_country" => splitext(basename(gpkg))[1],
                "input_bytes" => string(info.size), "input_mtime" => string(info.mtime))
end

quote_identifier(name) = "\"" * replace(name, "\"" => "\"\"") * "\""

function query(gpkg, sql)
    result = read(`sqlite3 -readonly -json $gpkg $sql`, String)
    return isempty(strip(result)) ? [] : JSON.parse(result)
end

# Set the parent resolution and mark its unused H3 digits as 7.
function parent_cell(cell)
    ((cell >> 52) & 0xf) == SAMPLE_RESOLUTION || error("Wrong sample resolution")
    return (cell & ~(UInt64(0xf) << 52)) | (UInt64(OUTPUT_RESOLUTION) << 52) | PARENT_UNUSED
end

function samples_per_cell(cell)
    base = (cell >> 45) & 0x7f
    digits = cell & ((UInt64(1) << 45) - 1)
    pentagon = base in (4, 14, 24, 38, 49, 58, 63, 72, 83, 97, 107, 117) && digits == PARENT_UNUSED
    count = 7^(SAMPLE_RESOLUTION - OUTPUT_RESOLUTION)
    return pentagon ? (5 * count + 1) ÷ 6 : count
end

function h3mon_table(levels)
    energy = Dict{UInt64,Float64}()
    for ((_, sample), db) in levels
        cell = parent_cell(sample)
        energy[cell] = get(energy, cell, 0.0) + 10.0^(db / 10)
    end
    cells = sort!(collect(keys(energy)))
    return (index_upper=[(cell >> 32) % UInt32 for cell in cells],
            index_lower=[cell % UInt32 for cell in cells],
            value=[Float32(10 * log10(energy[cell] / samples_per_cell(cell))) for cell in cells])
end

function write_fine_cache(file, levels; metadata=FINE_METADATA)
    ordered = sort!(collect(keys(levels)); by=last)
    family = UInt8[FAMILY_IDS[key[1]] for key in ordered]
    cells = UInt64[key[2] for key in ordered]
    values = Float32[levels[key] for key in ordered]
    open(Arrow.Writer, file; compress=nothing, dictencode=false, ntasks=1, metadata) do writer
        if isempty(cells)
            Arrow.write(writer, (source_family=family, h3=cells, level=values))
        end
        first = 1
        while first <= length(cells)
            stop = searchsortedlast(cells, cells[first] | ((UInt64(1) << 45) - 1))
            rows = first:stop
            Arrow.write(writer, (source_family=view(family, rows), h3=view(cells, rows), level=view(values, rows)))
            first = stop + 1
        end
    end
end

function collect_samples(input, levels, family)
    features = cells = empty_features = 0
    for line in eachline(input)
        fields = split(line, '\t'; limit=2, keepempty=true)
        length(fields) == 2 || error("Invalid keyed H3 record")
        level = BAND_LEVELS[JSON.parse(fields[1])]
        coverage = parse_cells(fields[2])
        features += 1
        cells += length(coverage)
        empty_features += isempty(coverage)
        for sample in coverage
            ((sample >> 52) & 0xf) == SAMPLE_RESOLUTION || error("Wrong H3 resolution")
            key = (family, sample)
            levels[key] = max(get(levels, key, -Inf), level)
        end
    end
    return (; features, cells, empty_features)
end

function convert_country(gpkg, destination; fine_cache=false)
    gpkg, destination = abspath(gpkg), abspath(destination)
    country = splitext(basename(gpkg))[1]
    started = time_ns()
    ispath(destination) && error("Output already exists: $destination")
    readchomp(`sqlite3 -readonly $gpkg 'PRAGMA quick_check'`) == "ok" ||
        error("GeoPackage integrity check failed")
    layers = query(gpkg, "SELECT table_name FROM gpkg_geometry_columns WHERE table_name GLOB '*_Lden' ORDER BY table_name")
    isempty(layers) && error("No Lden layers found")
    levels = Dict{Tuple{String,UInt64},Float64}()
    fingerprints = Set{Tuple{String,String}}()
    binary = joinpath(CONVERTER, "rust", "target", "release", "geojson_to_h3_rs")
    command = `$binary -r$SAMPLE_RESOLUTION --nocompact --containment center --polygon-only`
    mkpath(dirname(destination))
    mktempdir(dirname(destination)) do temporary
        for layer in layers
            layer_started = time_ns()
            name = layer["table_name"]
            table = quote_identifier(name)
            features = query(gpkg, "SELECT category, source, countryCode, geom IS NULL AS null_geometry FROM $table")
            isempty(features) && continue
            source = only(unique(f["source"] for f in features))
            all(f -> f["countryCode"] == country, features) || error("Country mismatch in $name")
            family = SOURCE_FAMILIES[source]
            all(f -> haskey(BAND_LEVELS, f["category"]), features) || error("Unknown band in $name")
            sql = "SELECT hex(sha3(group_concat(record,''),256)) FROM (SELECT hex(sha3(category || ':' || hex(geom),256)) AS record FROM $table ORDER BY record)"
            fingerprint = readchomp(`sqlite3 -readonly $gpkg $sql`)
            if (family, fingerprint) in fingerprints
                @info "Skipping duplicate report" source
                continue
            end
            push!(fingerprints, (family, fingerprint))
            expected_features = count(f -> f["null_geometry"] == 0, features)
            @info "Sampling cell centres" source resolution=SAMPLE_RESOLUTION features=length(features) null_geometries=length(features)-expected_features prepare_seconds=(time_ns()-layer_started)/1e9
            features = nothing
            flush(stderr)
            sql = "SELECT geom, category FROM $table WHERE geom IS NOT NULL"
            ogr = `ogr2ogr -f GeoJSONSeq /vsistdout/ $gpkg -dialect SQLite -sql $sql -makevalid -t_srs EPSG:4326 -lco RS=NO`
            sampling_started = time_ns()
            counts = open(pipeline(ogr, `$command --stream --key category`), "r") do input
                collect_samples(input, levels, family)
            end
            counts.features == expected_features || error("Feature count mismatch in $source")
            @info "Layer complete" source counts... sampling_seconds=(time_ns()-sampling_started)/1e9 total_seconds=(time_ns()-layer_started)/1e9
            flush(stderr)
        end
        isempty(levels) && !fine_cache && error("No cell centres covered")
        file = joinpath(temporary, "combined.arrow")
        if fine_cache
            write_fine_cache(file, levels; metadata=merge(FINE_METADATA, input_metadata(gpkg)))
            rows = length(levels)
        else
            output = h3mon_table(levels)
            Arrow.write(file, output; compress=nothing, dictencode=false)
            rows = length(output.value)
        end
        mv(file, destination)
        @info "Country complete" country rows source_samples=length(levels) fine_cache seconds=(time_ns()-started)/1e9 destination
        flush(stderr)
    end
end

function ensure_fine_cache(gpkg, destination)
    mkpath(dirname(abspath(destination)))
    open(destination * ".lock", "w") do lock
        # Keep the lock file: removing it can permit two locks on different inodes.
        Base.systemerror("flock", ccall(:flock, Cint, (Cint, Cint), fd(lock), 2) != 0)
        if ispath(destination)
            expected = merge(FINE_METADATA, input_metadata(gpkg))
            metadata_matches(Arrow.getmetadata(Arrow.Table(destination)), expected) ||
                error("Stale or incompatible cache: $destination")
            @info "Reusing country cache" destination
        else
            convert_country(gpkg, destination; fine_cache=true)
        end
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    fine_cache = !isempty(ARGS) && first(ARGS) == "--fine-cache"
    arguments = fine_cache ? ARGS[2:end] : ARGS
    length(arguments) == 2 || error("Usage: convert_country.jl [--fine-cache] INPUT.gpkg OUTPUT.arrow")
    fine_cache ? ensure_fine_cache(arguments...) : convert_country(arguments...)
end
