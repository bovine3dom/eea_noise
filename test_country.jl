using Test
include("convert_country.jl")

@testset "H3-MON energy averaging" begin
    cell = parse(UInt64, "8a1fb4662407fff"; base=16)
    parent = parse(UInt64, "881fb46625fffff"; base=16)
    table = h3mon_table(Dict(("roads", cell) => 60.0, ("industry", cell) => 60.0))
    @test propertynames(table) == (:index_upper, :index_lower, :value)
    @test eltype(table.index_upper) == eltype(table.index_lower) == UInt32
    @test eltype(table.value) == Float32
    @test table.value[1] ≈ Float32(10 * log10(2e6 / 49))
    @test (UInt64(table.index_upper[1]) << 32) | table.index_lower[1] == parent
    @test BAND_LEVELS["LdenLowerThan40"] == 37.5
    @test BAND_LEVELS["LdenGreaterThan75"] == 77.5
    @test parent_cell(cell) == parent
    @test parent_cell(parse(UInt64, "8a1fb4662447fff"; base=16)) == parent
    @test samples_per_cell(parent) == 49
    @test_throws ErrorException parent_cell(parent)

    children = [cell | (UInt64(i) << 18) | (UInt64(j) << 15) for i in 0:6 for j in 0:6]
    @test all(child -> parent_cell(child) == parent, children)
    @test only(h3mon_table(Dict(("roads", child) => 60.0 for child in children)).value) ≈ 60f0
    uniform = Dict((source, child) => 60.0 for source in ("roads", "industry") for child in children)
    @test only(h3mon_table(uniform).value) ≈ 63.0103f0
    @test only(h3mon_table(Dict(("roads", cell) => 60.0)).value) ≈ Float32(60 - 10 * log10(49))
    mixed = Dict(("roads", child) => (i <= 25 ? 60.0 : 40.0) for (i, child) in enumerate(children))
    @test only(h3mon_table(mixed).value) ≈ Float32(10 * log10((25e6 + 24e4) / 49))

    pentagon = parse(UInt64, "8808000001fffff"; base=16)
    pentagon_child = parse(UInt64, "8a0800000007fff"; base=16)
    @test parent_cell(pentagon_child) == pentagon
    @test samples_per_cell(pentagon) == 41
    pentagon_children = [pentagon_child | (UInt64(i) << 18) | (UInt64(j) << 15)
                         for i in 0:6 for j in 0:6 if i != 1 && !(i == 0 && j == 1)]
    @test length(pentagon_children) == 41
    @test only(h3mon_table(Dict(("roads", child) => 60.0 for child in pentagon_children)).value) ≈ 60f0
end

@testset "Keyed cell stream" begin
    sample = parse(UInt64, "8a1fb4662407fff"; base=16)
    input = "\"Lden5559\"\t8a1fb4662407fff\n\"Lden6569\"\t8a1fb4662407fff\n\"Lden6064\"\t\n"
    levels = Dict{Tuple{String,UInt64},Float64}()
    counts = collect_samples(IOBuffer(input), levels, "roads")
    @test counts == (features=3, cells=2, empty_features=1)
    @test levels == Dict(("roads", sample) => 67.5)
    @test collect_samples(IOBuffer(""), levels, "roads") == (features=0, cells=0, empty_features=0)
    @test_throws ErrorException collect_samples(IOBuffer("bad record\n"), levels, "roads")
    @test_throws KeyError collect_samples(IOBuffer("\"unknown\"\t\n"), levels, "roads")
    @test_throws ErrorException collect_samples(IOBuffer("\"Lden6064\"\t881fb46625fffff\n"), levels, "roads")
end

@testset "Centre sampling and duplicate reports" begin
    mktempdir() do directory
        gpkg = joinpath(directory, "ZZ.gpkg")
        x, y = 2.3513298555659152, 48.85434004428178
        ring(x, y) = [[x-0.000001, y-0.000001], [x+0.000001, y-0.000001],
                      [x+0.000001, y+0.000001], [x-0.000001, y+0.000001], [x-0.000001, y-0.000001]]
        roads = [("Lden5559", true), ("Lden6569", true), ("Lden6064", false)]
        for (source, bands) in [("roadsInAgglomeration", roads),
                                ("industryInAgglomeration", [("Lden6064", true)]),
                                ("majorRoadsIncludingAgglomeration", reverse(roads))]
            features = [Dict("type" => "Feature", "properties" => Dict(
                "category" => band, "source" => source, "countryCode" => "ZZ"),
                "geometry" => present ? Dict("type" => "Polygon", "coordinates" => [ring(x, y)]) : nothing)
                for (band, present) in bands]
            if source == "industryInAgglomeration"
                outside = deepcopy(features[1])
                outside["properties"]["category"] = "LdenGreaterThan75"
                outside["geometry"]["coordinates"] = [ring(2.35, 48.85)]
                push!(features, outside)
                collapsed = deepcopy(features[1])
                collapsed["geometry"] = Dict("type" => "LineString", "coordinates" => [[x, y], [x+0.000001, y]])
                push!(features, collapsed)
            end
            input = joinpath(directory, "$source.geojson")
            write(input, JSON.json(Dict("type" => "FeatureCollection", "features" => features)))
            layer = "NoiseContours_$(source)_Lden"
            options = isfile(gpkg) ? ["-update"] : String[]
            run(`ogr2ogr $options -f GPKG $gpkg $input -nln $layer -nlt GEOMETRY -lco GEOMETRY_NAME=geom`)
        end
        output = joinpath(directory, "output.arrow")
        convert_country(gpkg, output)
        table = Arrow.Table(output)
        @test propertynames(table) == [:index_upper, :index_lower, :value]
        @test length(table.value) == 1
        @test table.value[1] ≈ Float32(10 * log10((10^6.75 + 10^6.25) / 49))
        @test_throws ErrorException convert_country(gpkg, output)

        run(`ogrinfo $gpkg -sql "UPDATE NoiseContours_majorRoadsIncludingAgglomeration_Lden SET category='Lden7074' WHERE category='Lden5559'"`)
        partial = joinpath(directory, "partial.arrow")
        convert_country(gpkg, partial)
        @test only(Arrow.Table(partial).value) ≈ Float32(10 * log10((10^7.25 + 10^6.25) / 49))

        cache = joinpath(directory, "fine.arrow")
        command = `$(Base.julia_cmd()) --project=$CONVERTER $(joinpath(@__DIR__, "convert_country.jl")) --fine-cache $gpkg $cache`
        processes = [run(pipeline(command; stdout=devnull, stderr=devnull); wait=false) for _ in 1:2]
        foreach(wait, processes)
        @test all(success, processes)
        @test metadata_matches(Arrow.getmetadata(Arrow.Table(cache)), merge(FINE_METADATA, input_metadata(gpkg)))
        original = read(cache)
        ensure_fine_cache(gpkg, cache)
        @test read(cache) == original

        bin = joinpath(directory, "bin")
        mkpath(bin)
        record = Dict("type" => "Feature", "properties" => Dict("category" => "Lden6064"),
                      "geometry" => Dict("type" => "Polygon", "coordinates" => [ring(x, y)]))
        producer = joinpath(bin, "ogr2ogr")
        write(producer, "#!/bin/sh\nprintf '%s\\n' '$(JSON.json(record))'\nexit 7\n")
        chmod(producer, 0o755)
        withenv("PATH" => bin * ":" * ENV["PATH"]) do
            failed = joinpath(directory, "producer-failed.arrow")
            @test_throws ProcessFailedException convert_country(gpkg, failed)
            @test !ispath(failed)
        end

        run(`ogrinfo $gpkg -sql "UPDATE NoiseContours_industryInAgglomeration_Lden SET category='unknown'"`)
        @test_throws ErrorException ensure_fine_cache(gpkg, cache)
        @test_throws ErrorException convert_country(gpkg, joinpath(directory, "failed.arrow"))
        @test !ispath(joinpath(directory, "failed.arrow"))
    end
end
