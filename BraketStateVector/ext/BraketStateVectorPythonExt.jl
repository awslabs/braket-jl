module BraketStateVectorPythonExt

using BraketStateVector, BraketStateVector.Braket, PythonCall

import BraketStateVector.Braket: LocalSimulator, qubit_count, _run_internal, Instruction, Observables, AbstractProgramResult, ResultTypeValue, format_result, LocalQuantumTask, LocalQuantumTaskBatch, GateModelQuantumTaskResult, GateModelTaskResult, Program, Gate, AngledGate, IRObservable
import BraketStateVector: AbstractSimulator, classical_shadow, AbstractStateVector, apply_gate!, get_amps_and_qubits, pad_bits, flip_bits, flip_bit

const pennylane = PythonCall.pynew()
const braket    = PythonCall.pynew()

include("custom_gates.jl")
include("translation.jl")

function __init__()
    # must set these when this code is actually loaded
    PythonCall.pycopy!(braket,    pyimport("braket"))
    PythonCall.pycopy!(pennylane, pyimport("pennylane"))
    PythonCall.pyconvert_add_rule("pennylane.ops.op_math:Adjoint", Instruction, pennylane_convert_Adjoint)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliX", Instruction, pennylane_convert_X)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliY", Instruction, pennylane_convert_Y)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliZ", Instruction, pennylane_convert_Z)
    PythonCall.pyconvert_add_rule("pennylane.ops.identity:Identity", Instruction, pennylane_convert_I)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:Hadamard", Instruction, pennylane_convert_H)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:S", Instruction, pennylane_convert_S)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:SX", Instruction, pennylane_convert_V)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:T", Instruction, pennylane_convert_T)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:CNOT", Instruction, pennylane_convert_CNOT)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:CY", Instruction, pennylane_convert_CY)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:CZ", Instruction, pennylane_convert_CZ)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:Toffoli", Instruction, pennylane_convert_Toffoli)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:SWAP", Instruction, pennylane_convert_SWAP)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:ISWAP", Instruction, pennylane_convert_ISWAP)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_multi_qubit:PSWAP", Instruction, pennylane_convert_PSWAP)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:CSWAP", Instruction, pennylane_convert_CSWAP)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:ECR", Instruction, pennylane_convert_ECR)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_single_qubit:RX", Instruction, pennylane_convert_RX)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_single_qubit:RY", Instruction, pennylane_convert_RY)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_single_qubit:RZ", Instruction, pennylane_convert_RZ)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_single_qubit:PhaseShift", Instruction, pennylane_convert_PhaseShift)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_controlled:ControlledPhaseShift", Instruction, pennylane_convert_ControlledPhaseShift)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_controlled:CPhaseShift00", Instruction, pennylane_convert_CPhaseShift00)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_controlled:CPhaseShift01", Instruction, pennylane_convert_CPhaseShift01)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_controlled:CPhaseShift10", Instruction, pennylane_convert_CPhaseShift10)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_multi_qubit:IsingXX", Instruction, pennylane_convert_IsingXX)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_multi_qubit:IsingXY", Instruction, pennylane_convert_IsingXY)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_multi_qubit:IsingYY", Instruction, pennylane_convert_IsingYY)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.parametric_ops_multi_qubit:IsingZZ", Instruction, pennylane_convert_IsingZZ)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.qchem_ops:DoubleExcitation", Instruction, pennylane_convert_DoubleExcitation)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.qchem_ops:SingleExcitation", Instruction, pennylane_convert_SingleExcitation)
    PythonCall.pyconvert_add_rule("builtins:list", Union{Float64, FreeParameter}, pennylane_convert_parameters)
    PythonCall.pyconvert_add_rule("builtins:list", Union{Dict{String, Float64}, Vector{Dict{String, Float64}}}, pennylane_convert_inputs)
    #PythonCall.pyconvert_add_rule("pennylane:Hamiltonian", Observables.Observable, pennylane_convert_Hamiltonian)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliX", Observables.Observable, pennylane_convert_X)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliY", Observables.Observable, pennylane_convert_Y)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliZ", Observables.Observable, pennylane_convert_Z)
    PythonCall.pyconvert_add_rule("pennylane.ops.identity:Identity", Observables.Observable, pennylane_convert_I)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:Hadamard", Observables.Observable, pennylane_convert_H)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.observables:Hermitian", Observables.Observable, pennylane_convert_Hermitian)
    PythonCall.pyconvert_add_rule("pennylane.operation:Tensor", Observables.Observable, pennylane_convert_Tensor)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliX", Tuple{IRObservable, Vector{Int}}, pennylane_convert_X)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliY", Tuple{IRObservable, Vector{Int}}, pennylane_convert_Y)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:PauliZ", Tuple{IRObservable, Vector{Int}}, pennylane_convert_Z)
    PythonCall.pyconvert_add_rule("pennylane.ops.identity:Identity", Tuple{IRObservable, Vector{Int}}, pennylane_convert_I)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.non_parametric_ops:Hadamard", Tuple{IRObservable, Vector{Int}}, pennylane_convert_H)
    PythonCall.pyconvert_add_rule("pennylane.ops.qubit.observables:Hermitian", Tuple{IRObservable, Vector{Int}}, pennylane_convert_Hermitian)
    PythonCall.pyconvert_add_rule("pennylane.operation:Tensor", Tuple{IRObservable, Vector{Int}}, pennylane_convert_Tensor)
    PythonCall.pyconvert_add_rule("pennylane.measurements.expval:ExpectationMP", BraketStateVector.Braket.IR.AbstractProgramResult, pennylane_convert_ExpectationMP)
    PythonCall.pyconvert_add_rule("pennylane.measurements.var:VarianceMP", BraketStateVector.Braket.IR.AbstractProgramResult, pennylane_convert_VarianceMP)
    PythonCall.pyconvert_add_rule("pennylane.measurements.sample:SampleMP", BraketStateVector.Braket.IR.AbstractProgramResult, pennylane_convert_SampleMP)
    #PythonCall.pyconvert_add_rule("pennylane.tape.qscript:QuantumScript", Any, pennylane_convert_QuantumScript)
    PythonCall.pyconvert_add_rule("pennylane.tape.qscript:QuantumScript", BraketStateVector.Braket.IR.Program, pennylane_convert_QuantumScript)
end
BraketStateVector.Braket.qubit_count(o::Py) = pyisinstance(o, pennylane.tape.QuantumTape) ? length(o.wires) : o.qubit_count

function _build_programs_from_args(raw_task_specs)
    N = length(raw_task_specs)
    jl_specs = Vector{Program}(undef, N)
    Threads.@threads for ix in 1:N
        instructions   = raw_task_specs[ix][1]
        results_list   = raw_task_specs[ix][2]
        instr_qubits   = mapreduce(ix->ix.target, union, instructions)
        result_qubits  = mapreduce(ix->hasproperty(ix, :targets) ? ix.targets : Set{Int}(), union, results_list, init=Set{Int}())
        all_qubits     = union(result_qubits, instr_qubits) 
        missing_qubits = union(setdiff(result_qubits, instr_qubits), setdiff(0:maximum(all_qubits), instr_qubits))
        for q in missing_qubits
            push!(instructions, Instruction(Braket.I(), q))
        end
        BraketStateVector._validate_operation_qubits(instructions)
        jl_specs[ix]   = BraketStateVector.Braket.IR.Program(BraketStateVector.Braket.header_dict[BraketStateVector.Braket.IR.Program], instructions, results_list, Instruction[])
    end
    return jl_specs
end

function classical_shadow(d::LocalSimulator, obs_qubits, circuit, shots::Int, seed::Int)
    raw_jl_spec = _translate_from_python(circuit, d._delegate)
    PythonCall.GC.disable()
    jl_spec = pyconvert(Program, circuit)
    shadow = classical_shadow(d, pyconvert(Vector{Int}, obs_qubits), jl_spec, shots, seed)
    PythonCall.GC.enable()
    return shadow
end

function classical_shadow(d::LocalSimulator, obs_qubits, circuits::NTuple{N, T}, shots::Int, seed::PyList) where {N, T}
    jl_obs_qubits = pyconvert(Vector{Vector{Int}}, obs_qubits)
    jl_seed       = pyconvert(Vector{Int}, seed)
    PythonCall.GC.disable()
    jl_specs      = [pyconvert(Program, circuit) for circuit in circuits]
    shadow        = classical_shadow(d, jl_obs_qubits, jl_specs, shots, jl_seed)
    PythonCall.GC.enable()
    return shadow 
end

function (d::LocalSimulator)(task_specs::PyList{Any}, inputs::Union{PyList{Any}, PyDict{Any, Any}}, args...; kwargs...)
    # handle inputs
    if inputs isa PyDict{Any, Any}
        jl_inputs = pyconvert(Dict{String, Float64}, inputs)
    else
        jl_inputs = [pyconvert(Dict{String, Float64}, py_inputs) for py_inputs in inputs]
    end
    jl_specs   = [pyconvert(Program, spec) for spec in task_specs]
    jl_results = results(d(jl_specs, args...; inputs=jl_inputs, kwargs...))
    #py_res     = [py_results(task_spec[2], d._delegate, result) for (task_spec, result) in zip(task_specs, jl_results)]
    #return py_res
    return jl_results
end

Py(r::GateModelQuantumTaskResult) = Py(r.values)
#=

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
=#
end
