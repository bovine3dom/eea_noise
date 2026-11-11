include("convert_country.jl")

function merge_dataset(files, destination)
    destination = abspath(destination)
    ispath(destination) && error("Output already exists: $destination")
    isempty(files) && error("No country caches supplied")
    bases = Set{UInt64}()
    input_samples = 0
    for file in files, batch in Arrow.Stream(file)
        metadata_matches(Arrow.getmetadata(batch), FINE_METADATA) || error("Cache model mismatch: $file")
        propertynames(batch) == [:source_family, :h3, :level] || error("Invalid cache schema: $file")
        input_samples += length(batch.h3)
        isempty(batch.h3) || push!(bases, base_cell(first(batch.h3)))
    end
    isempty(bases) && error("No samples in country caches")
    rows = unique_samples = 0
    mkpath(dirname(destination))
    mktempdir(dirname(destination)) do temporary
        partial = joinpath(temporary, "merged.arrow")
        open(Arrow.Writer, partial; compress=nothing, dictencode=false, ntasks=1) do writer
            for base in sort!(collect(bases))
                levels = Dict{Tuple{UInt8,UInt64},Float64}()
                for file in files, batch in Arrow.Stream(file)
                    isempty(batch.h3) && continue
                    base_cell(first(batch.h3)) == base || continue
                    all(cell -> base_cell(cell) == base, batch.h3) || error("Mixed base cells: $file")
                    for i in eachindex(batch.h3)
                        family, sample, level = batch.source_family[i], batch.h3[i], batch.level[i]
                        family in values(FAMILY_IDS) || error("Unknown source family in $file")
                        isfinite(level) || error("Invalid noise level in $file")
                        key = (family, sample)
                        levels[key] = max(get(levels, key, -Inf), level)
                    end
                end
                table = h3mon_table(levels)
                Arrow.write(writer, table)
                rows += length(table.value)
                unique_samples += length(levels)
                @info "Merged base cell" base source_samples=length(levels) output_cells=length(table.value)
                flush(stderr)
            end
        end
        mv(partial, destination)
    end
    return (; countries=length(files), cells=rows, input_samples, unique_samples,
             duplicate_source_samples=input_samples-unique_samples)
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    length(ARGS) >= 2 || error("Usage: merge_dataset.jl OUTPUT.arrow COUNTRY_CACHE.arrow [...]")
    println(JSON.json(merge_dataset(ARGS[2:end], first(ARGS))))
end
