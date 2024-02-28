mutable struct DensityMatrixSimulator{T,S} <:
               AbstractSimulator where {T,S<:AbstractDensityMatrix{T}}
    density_matrix::S
    qubit_count::Int
    shots::Int
    shot_buffer::Vector{Int}
    _alias::Vector{Int}
    _ap::Vector{Float64}
    _larges::Vector{Int}
    _smalls::Vector{Int}
    _density_matrix_after_observables::S
    function DensityMatrixSimulator{T,S}(
        density_matrix::S,
        qubit_count::Int,
        shots::Int,
    ) where {T,S<:AbstractDensityMatrix{T}}
        shot_buffer = Vector{Int}(undef, shots)
        ap_len  = ap_size(shots, qubit_count)
        _ap     = zeros(Float64, ap_len)
        _alias  = zeros(Int, ap_len)
        _larges = zeros(Int, ap_len)
        _smalls = zeros(Int, ap_len)
        return new(
            density_matrix,
            qubit_count,
            shots,
            shot_buffer,
            _alias,
            _ap,
            _larges,
            _smalls,
            S(undef, 0, 0),
        )
    end
end
function init(
    ::Type{DensityMatrixSimulator{T,S}},
    qubit_count::Int,
) where {T,S<:AbstractMatrix{T}}
    dm = S(undef, 2^qubit_count, 2^qubit_count)
    fill!(dm, zero(T))
    dm[1, 1] = one(T)
    return dm
end
function DensityMatrixSimulator{T,S}(
    qubit_count::Int,
    shots::Int,
) where {T,S<:AbstractDensityMatrix{T}}
    dm = init(DensityMatrixSimulator{T,S}, qubit_count)
    return DensityMatrixSimulator{T,S}(dm, qubit_count, shots)
end
DensityMatrixSimulator(::Type{T}, qubit_count::Int, shots::Int) where {T<:Number} =
    DensityMatrixSimulator{T,DensityMatrix{T}}(qubit_count, shots)
DensityMatrixSimulator(qubit_count::Int, shots::Int) =
    DensityMatrixSimulator(ComplexF64, qubit_count, shots)
Braket.qubit_count(dms::DensityMatrixSimulator) = dms.qubit_count
Braket.properties(d::DensityMatrixSimulator) = dm_props
supported_operations(d::DensityMatrixSimulator) =
    dm_props.action["braket.ir.openqasm.program"].supportedOperations
supported_result_types(d::DensityMatrixSimulator) =
    dm_props.action["braket.ir.openqasm.program"].supportedResultTypes
Braket.device_id(dms::DensityMatrixSimulator) = "braket_dm"
Braket.name(dms::DensityMatrixSimulator) = "DensityMatrixSimulator"
Base.show(io::IO, dms::DensityMatrixSimulator) =
    print(io, "DensityMatrixSimulator(qubit_count=$(qubit_count(dms)), shots=$(dms.shots))")
Base.similar(
    dms::DensityMatrixSimulator{T,S};
    shots::Int = dms.shots,
) where {T,S<:AbstractDensityMatrix{T}} =
    DensityMatrixSimulator{T,S}(dms.qubit_count, shots)
Base.copy(dms::DensityMatrixSimulator{T,S}) where {T,S<:AbstractDensityMatrix{T}} =
    DensityMatrixSimulator{T,S}(deepcopy(dms.density_matrix), dms.qubit_count, dms.shots)
function Base.copyto!(
    dst::DensityMatrixSimulator{T,S},
    src::DensityMatrixSimulator{T,S},
) where {T,S}
    copyto!(dst.density_matrix, src.density_matrix)
    return dst
end

function reinit!(
    dms::DensityMatrixSimulator{T,S},
    qubit_count::Int,
    shots::Int,
) where {T,S<:AbstractDensityMatrix{T}}
    n = 2^qubit_count
    if size(dms.density_matrix) != (n, n)
        dms.density_matrix = S(undef, n, n)
        ap_len = ap_size(shots, qubit_count)
        resize!(dms._alias, ap_len)
        resize!(dms._ap, ap_len)
        resize!(dms._larges, ap_len)
        resize!(dms._smalls, ap_len)
    end
    if dms.shots != shots
        ap_len = ap_size(shots, qubit_count)
        resize!(dms._alias, ap_len)
        resize!(dms._ap, ap_len)
        resize!(dms._larges, ap_len)
        resize!(dms._smalls, ap_len)
        resize!(dms.shot_buffer, shots)
    end
    fill!(dms.density_matrix, zero(T))
    dms._ap          .= zero(Float64)
    dms._alias       .= zero(Int)
    dms._larges      .= zero(Int)
    dms._smalls      .= zero(Int)
    dms.density_matrix[1, 1] = one(T)
    dms.qubit_count = qubit_count
    dms.shots = shots
    dms._density_matrix_after_observables = S(undef, 0, 0)
    return
end

function _evolve_op!(
    dms::DensityMatrixSimulator{T,S},
    op::G,
    target::Int...,
) where {T<:Complex,S<:AbstractDensityMatrix{T},G<:Gate}
    reshaped_dm = reshape(dms.density_matrix, length(dms.density_matrix))
    apply_gate!(Val(false), op, reshaped_dm, target...)
    #display(reshaped_dm)
    #println()
    apply_gate!(Val(true),  op, reshaped_dm, (dms.qubit_count .+ target)...)
    #display(reshaped_dm)
    #println()
    return
end

function _evolve_op!(
    dms::DensityMatrixSimulator{T,S},
    op::N,
    target::Int...,
) where {T<:Complex,S<:AbstractDensityMatrix{T},N<:Noise}
    apply_noise!(op, dms.density_matrix, target...)
end

function evolve!(
    dms::DensityMatrixSimulator{T,S},
    operations::Vector{Instruction},
) where {T<:Complex,S<:AbstractDensityMatrix{T}}
    for op in operations
        # use this to dispatch on Gates vs Noises
        _evolve_op!(dms, op.operator, op.target...)
    end
    return dms
end

for (gate, obs) in (
    (:X, :(Braket.Observables.X)),
    (:Y, :(Braket.Observables.Y)),
    (:Z, :(Braket.Observables.Z)),
    (:I, :(Braket.Observables.I)),
    (:H, :(Braket.Observables.H)),
)
    @eval begin
        function apply_observable!(
            observable::$obs,
            dm::S,
            targets,
        ) where {T<:Complex,S<:AbstractDensityMatrix{T}}
            nq = Int(log2(size(dm, 1)))
            reshaped_dm = reshape(dm, length(dm))
            for target in targets
                apply_gate!($gate(), reshaped_dm, target)
            end
            return dm
        end
    end
end
function apply_observable!(
    observable::Braket.Observables.HermitianObservable,
    dm::DensityMatrix{T},
    targets::Int...,
) where {T<:Complex}
    nq = Int(log2(size(dm, 1)))
    n_amps = 2^nq
    ts = collect(targets)
    endian_ts = nq - 1 .- ts
    o_mat = transpose(observable.matrix)

    ordered_ts = sort(collect(endian_ts))
    flip_list = map(0:2^length(ts)-1) do t
        f_vals = Bool[(((1 << f_ix) & t) >> f_ix) for f_ix = 0:length(ts)-1]
        return ordered_ts[f_vals]
    end
    slim_size = div(n_amps, 2^length(ts))
    Threads.@threads for raw_ix = 0:(slim_size^2)-1
        ix = div(raw_ix, slim_size)
        jx = mod(raw_ix, slim_size)
        padded_ix = pad_bits(ix, ordered_ts)
        padded_jx = pad_bits(jx, ordered_ts)
        ixs = map(flip_list) do f
            flipped_ix = padded_ix
            for f_val in f
                flipped_ix = flip_bit(flipped_ix, f_val)
            end
            return flipped_ix + 1
        end
        jxs = map(flip_list) do f
            flipped_jx = padded_jx
            for f_val in f
                flipped_jx = flip_bit(flipped_jx, f_val)
            end
            return flipped_jx + 1
        end
        @views begin
            elems = dm[jxs[:], ixs[:]]
            dm[jxs[:], ixs[:]] = o_mat * elems
        end
    end
    return dm
end

function state_with_observables(dms::DensityMatrixSimulator)
    isempty(dms._density_matrix_after_observables) &&
        error("observables have not been applied.")
    return dms._density_matrix_after_observables
end

function apply_observables!(dms::DensityMatrixSimulator, observables)
    !isempty(dms._density_matrix_after_observables) &&
        error("observables have already been applied.")
    diag_gates = [diagonalizing_gates(obs...) for obs in observables]
    operations = reduce(vcat, diag_gates)
    dms._density_matrix_after_observables = deepcopy(dms.density_matrix)
    reshaped_dm = reshape(dms._density_matrix_after_observables, length(dms.density_matrix))
    for op in operations
        apply_gate!(Val(false), op.operator, reshaped_dm, op.target...)
        apply_gate!(Val(true), op.operator, reshaped_dm, (dms.qubit_count .+ op.target)...)
    end
    return dms
end

function expectation(
    dms::DensityMatrixSimulator,
    observable::Observables.Observable,
    targets::Int...,
)
    dm_copy = apply_observable(observable, dms.density_matrix, targets...)
    return real(sum(diag(dm_copy)))
end
state_vector(dms::DensityMatrixSimulator) = diag(dms.density_matrix)
#    isdiag(dms.density_matrix) ? diag(dms.density_matrix) :
#    error("cannot express density matrix with off-diagonal elements as a pure state.")
density_matrix(dms::DensityMatrixSimulator) = dms.density_matrix
probabilities(dms::DensityMatrixSimulator) = real.(diag(dms.density_matrix))

function swap_bits(ix::Int, qubit_map::Dict{Int,Int})
    # only flip 01 and 10
    for (in_q, out_q) in qubit_map
        if in_q < out_q
            in_val = ((1 << in_q) & ix) >> in_q
            out_val = ((1 << out_q) & ix) >> out_q
            if in_val != out_val
                ix = flip_bit(flip_bit(ix, in_q), out_q)
            end
        end
    end
    return ix
end

function partial_trace(
    ρ::AbstractMatrix{ComplexF64},
    output_qubits = collect(0:Int(log2(size(ρ, 1)))-1),
)
    isempty(output_qubits) && return sum(diag(ρ))
    n_amps = size(ρ, 1)
    nq = Int(log2(n_amps))
    length(unique(output_qubits)) == nq && return ρ

    qubits = setdiff(collect(0:nq-1), output_qubits)
    endian_qubits = sort(nq .- qubits .- 1)
    q_combos = vcat([Int[]], collect(combinations(endian_qubits)))
    final_ρ = zeros(ComplexF64, 2^(nq - length(qubits)), 2^(nq - length(qubits)))
    # handle possibly permuted targets
    needs_perm = !issorted(output_qubits)
    final_nq = length(output_qubits)
    output_qubit_mapping =
        needs_perm ?
        Dict(zip(final_nq .- output_qubits .- 1, final_nq .- collect(0:final_nq-1) .- 1)) :
        Dict{Int,Int}()
    for raw_ix = 0:length(final_ρ)-1
        ix = div(raw_ix, size(final_ρ, 1))
        jx = mod(raw_ix, size(final_ρ, 1))
        padded_ix = pad_bits(ix, endian_qubits)
        padded_jx = pad_bits(jx, endian_qubits)
        flipped_inds = Vector{CartesianIndex{2}}(undef, length(q_combos))
        for (c_ix, flipped_qs) in enumerate(q_combos)
            flipped_ix = padded_ix
            flipped_jx = padded_jx
            for flip_q in flipped_qs
                flipped_ix = flip_bit(flipped_ix, flip_q)
                flipped_jx = flip_bit(flipped_jx, flip_q)
            end
            flipped_inds[c_ix] = CartesianIndex{2}(flipped_ix + 1, flipped_jx + 1)
        end
        out_ix = needs_perm ? swap_bits(ix, output_qubit_mapping) : ix
        out_jx = needs_perm ? swap_bits(jx, output_qubit_mapping) : jx
        @views begin
            @inbounds trace_val = sum(ρ[flipped_inds])
            final_ρ[out_ix+1, out_jx+1] = trace_val
        end
    end
    return final_ρ
end
