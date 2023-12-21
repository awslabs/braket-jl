module BraketStateVectorPythonExt

using BraketStateVector, BraketStateVector.Braket, PythonCall

import BraketStateVector.Braket: LocalSimulator, qubit_count, _run_internal, Instruction, Observables, AbstractProgramResult, ResultTypeValue, format_result, LocalQuantumTask, LocalQuantumTaskBatch, GateModelQuantumTaskResult, GateModelTaskResult, Program
import BraketStateVector: AbstractSimulator

const pennylane = PythonCall.pynew()
const braket    = PythonCall.pynew()

function __init__()
    # must set these when this code is actually loaded
    PythonCall.pycopy!(braket,    pyimport("braket"))
    PythonCall.pycopy!(pennylane, pyimport("pennylane"))
end

BraketStateVector.Braket.qubit_count(o::Py) = pyisinstance(o, pennylane.tape.QuantumTape) ? length(o.wires) : o.qubit_count

include("translation.jl")

function _build_programs_from_args(raw_task_specs)
    N = length(raw_task_specs)
    jl_specs = Vector{Program}(undef, N)
    Threads.@threads for ix in 1:N
        instructions_args = raw_task_specs[ix].instructions_args
        results_args      = raw_task_specs[ix].results_args
        instructions      = Vector{Instruction}(undef, length(instructions_args))
        results_list      = Vector{AbstractProgramResult}(undef, length(results_args))
        Threads.@threads for inst_ix in 1:length(instructions_args)
            instructions[inst_ix] = _translate_operation(instructions_args[inst_ix]...)
        end
        Threads.@threads for res_ix in 1:length(results_args)
            results_list[res_ix] = _translate_result(results_args[res_ix]...)
        end
        instr_qubits   = mapreduce(ix->ix.target, union, instructions)
        result_qubits  = mapreduce(ix->hasproperty(ix, :targets) ? ix.targets : Set{Int}(), union, results_list)
        all_qubits     = union(result_qubits, instr_qubits) 
        missing_qubits = union(setdiff(result_qubits, instr_qubits), setdiff(0:maximum(all_qubits), instr_qubits))
        for q in missing_qubits
            push!(instructions, Instruction(Braket.I(), q))
        end
        #@show instr_qubits, missing_qubits
        BraketStateVector._validate_operation_qubits(instructions)
        jl_specs[ix]   = BraketStateVector.Braket.IR.Program(BraketStateVector.Braket.header_dict[BraketStateVector.Braket.IR.Program], instructions, results_list, Instruction[])
    end
    return jl_specs
end

function (d::LocalSimulator)(task_specs::NTuple{N, T}, args...; shots::Int=0, max_parallel::Int=-1, inputs::Union{Vector{Dict{String, Float64}}, Dict{String, Float64}} = Dict{String, Float64}(), kwargs...) where {N, T}
    is_single_task  = N == 1
    is_single_input = inputs isa Dict{String, Float64}
    !is_single_task && !is_single_input && N != length(inputs) && throw(ArgumentError("number of inputs ($(length(inputs))) and task specifications ($N)) must be equal."))
    is_single_input && (inputs = is_single_task ? [inputs] : fill(inputs, length(task_specs)))
    start = time()
    raw_jl_specs = Vector{NamedTuple}(undef, N)
    for ix in 1:N
        raw_jl_specs[ix] = _translate_from_python(task_specs[ix], d._delegate)
    end
    stop = time()
    @info "Time to translate circuits to args: $(stop-start)."
    start = time()
    PythonCall.GC.disable()
    jl_specs = _build_programs_from_args(raw_jl_specs)
    stop = time()
    @info "Time to build programs: $(stop-start)."
    flush(stdout)
    tasks_and_inputs = zip(1:N, jl_specs, inputs)

    start = time()
    raw_results = Vector{GateModelTaskResult}(undef, N)
    Threads.@threads for (ix, spec, input) in collect(tasks_and_inputs)
        sim = copy(d._delegate)
        raw_results[ix] = sim(spec, qubit_count(spec), args...; inputs=input, shots=shots, kwargs...)
    end
    stop = time()
    @info "Time to simulate batch: $(stop-start)."
    flush(stdout)
    start = time()
    results = Vector{GateModelQuantumTaskResult}(undef, N)
    Threads.@threads for ix in 1:length(raw_results)
        results[ix] = format_result(raw_results[ix])
    end
    PythonCall.GC.enable()
    stop = time()
    @info "Time to format results: $(stop-start)."
    start = time()
    py_res = [py_results(task_spec[2], d._delegate, result) for (task_spec, result) in zip(task_specs, results)]
    stop = time()
    @info "Time to convert results back to Python: $(stop-start)."
    return py_res
end

function _get_result_value(mp::Py, d::AbstractSimulator, braket_results::GateModelQuantumTaskResult)
    jl_mp = [BraketStateVector.Braket.StructTypes.constructfrom(BraketStateVector.Braket.Result, _translate_result(args...)) for args in _translate_result(mp, d)]
    if pyisinstance(mp.obs, pennylane.Hamiltonian)
        coeffs, _ = mp.obs.terms()
        H_exp = sum(pyconvert(Float64, coeff) * braket_results[rt] for (coeff, rt) in zip(coeffs, jl_mp))
        return Py(H_exp)
    else
        return Py(braket_results[jl_mp[1]])
    end
end

function py_results(py_measurements::PyList, d::AbstractSimulator, braket_results::GateModelQuantumTaskResult)
    return map(op->_get_result_value(op, d, braket_results), py_measurements)
end

end