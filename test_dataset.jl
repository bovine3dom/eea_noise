using Test
include("merge_dataset.jl")

@testset "Dataset border merge" begin
    mktempdir() do directory
        first_sample = parse(UInt64, "8a1fb4662407fff"; base=16)
        second_sample = parse(UInt64, "8a1fb4662447fff"; base=16)
        pentagon_sample = parse(UInt64, "8a0800000007fff"; base=16)
        a = Dict(("roads", first_sample) => 60.0, ("industry", first_sample) => 50.0,
                 ("roads", pentagon_sample) => 55.0)
        b = Dict(("roads", first_sample) => 57.5, ("roads", second_sample) => 60.0,
                 ("airports", first_sample) => 40.0)
        files = [joinpath(directory, "$name.arrow") for name in ("A", "B", "empty")]
        write_fine_cache(files[1], a)
        write_fine_cache(files[2], b; metadata=merge(FINE_METADATA, Dict("input_country" => "B")))
        write_fine_cache(files[3], Dict{Tuple{String,UInt64},Float64}())
        @test length(collect(Arrow.Stream(files[1]))) == 2
        output = joinpath(directory, "merged.arrow")
        summary = merge_dataset(files, output)
        expected = h3mon_table(mergewith(max, a, b))
        actual = Arrow.Table(output)
        @test summary.countries == 3
        @test summary.input_samples == 6
        @test summary.unique_samples == 5
        @test summary.duplicate_source_samples == 1
        @test summary.cells == 2
        run(`node $(joinpath(@__DIR__, "test_h3mon.mjs")) $output`)
        for name in propertynames(expected)
            @test collect(getproperty(actual, name)) == getproperty(expected, name)
        end
        @test_throws ErrorException merge_dataset(files, output)
        bad = joinpath(directory, "bad.arrow")
        Arrow.write(bad, expected; compress=nothing)
        @test_throws ErrorException merge_dataset([bad], joinpath(directory, "failed.arrow"))
        @test !ispath(joinpath(directory, "failed.arrow"))
        @test_throws ErrorException merge_dataset([files[3]], joinpath(directory, "empty.arrow"))
    end
end
