pennylane_convert_parameters(::Type{Float64}, x::Py) = PythonCall.pyconvert_return(pyconvert(Float64, x[0]))
pennylane_convert_parameters(::Type{FreeParameter}, x::Py) = PythonCall.pyconvert_return(FreeParameter(pyconvert(String, x[0])))

pennylane_convert_inputs(::Type{Dict{String, Float64}}, x::Py) = PythonCall.pyconvert_return(pyconvert(Dict{String, Float64}, x))
pennylane_convert_inputs(::Type{Vector{Dict{String, Float64}}}, x::Py) = PythonCall.pyconvert_return([pyconvert(Dict{String, Float64}, x_) for x_ in x])
for (conv_fn, jl_typ) in ((:pennylane_convert_X, :X),
                          (:pennylane_convert_Y, :Y),
                          (:pennylane_convert_Z, :Z),
                          (:pennylane_convert_I, :I),
                          (:pennylane_convert_H, :H),
                          (:pennylane_convert_S, :S),
                          (:pennylane_convert_T, :T),
                          (:pennylane_convert_V, :V),
                         )
    @eval begin
        function $conv_fn(::Type{Instruction}, x::Py)
            return PythonCall.pyconvert_return(Instruction($jl_typ(), pyconvert(Int, x.wires[0])))
        end
    end
end

for (conv_fn, jl_typ) in ((:pennylane_convert_RX, :Rx),
                          (:pennylane_convert_RY, :Ry),
                          (:pennylane_convert_RZ, :Rz),
                          (:pennylane_convert_PhaseShift, :PhaseShift),
                         )
    @eval begin
        function $conv_fn(::Type{Instruction}, x::Py)
            angle = pyconvert(Union{Float64, FreeParameter}, x.parameters)
            return PythonCall.pyconvert_return(Instruction($jl_typ(angle), pyconvert(Int, x.wires[0])))
        end
    end
end

for (conv_fn, jl_typ) in ((:pennylane_convert_IsingXX, :XX),
                          (:pennylane_convert_IsingYY, :YY),
                          (:pennylane_convert_IsingZZ, :ZZ),
                          (:pennylane_convert_IsingXY, :XY),
                          (:pennylane_convert_PSWAP, :PSwap),
                          (:pennylane_convert_ControlledPhaseShift, :CPhaseShift),
                          (:pennylane_convert_CPhaseShift00, :CPhaseShift00),
                          (:pennylane_convert_CPhaseShift01, :CPhaseShift01),
                          (:pennylane_convert_CPhaseShift10, :CPhaseShift10),
                          (:pennylane_convert_DoubleExcitation, :DoubleExcitation),
                          (:pennylane_convert_SingleExcitation, :SingleExcitation),
                         )
    @eval begin
        function $conv_fn(::Type{Instruction}, x::Py)
            angle = pyconvert(Union{Float64, FreeParameter}, x.parameters)
            return PythonCall.pyconvert_return(Instruction($jl_typ(angle), pyconvert(Vector{Int}, x.wires)))
        end
    end
end

for (conv_fn, jl_typ) in ((:pennylane_convert_CNOT, :CNot),
                          (:pennylane_convert_CY, :CY),
                          (:pennylane_convert_CZ, :CZ),
                          (:pennylane_convert_SWAP, :Swap),
                          (:pennylane_convert_ISWAP, :ISwap),
                          (:pennylane_convert_CSWAP, :CSwap),
                          (:pennylane_convert_ECR, :ECR),
                          (:pennylane_convert_Toffoli, :CCNot),
                         )
    @eval begin
        function $conv_fn(::Type{Instruction}, x::Py)
            return PythonCall.pyconvert_return(Instruction($jl_typ(), pyconvert(Vector{Int}, x.wires)))
        end
    end
end
function pennylane_convert_QubitUnitary(::Type{Instruction}, x::Py)
    mat = pyconvert(Matrix{ComplexF64}, x.parameters[0])
    return PythonCall.pyconvert_return(Instruction(Unitary(mat), pyconvert(Int, x.wires)))
end

for (typ, adj_typ) in ((:S, :Si), (:T, :Ti), (:V, :Vi))
    @eval begin
        adjoint_type(::Type{$typ}) = $adj_typ
        adjoint_type(g::$typ) = $adj_typ()
    end
end

function pennylane_convert_Adjoint(::Type{Instruction}, x::Py)
    un_adjointed_instruction = pyconvert(Instruction, x.base)
    raw_gate = un_adjointed_instruction.operator
    return PythonCall.pyconvert_return(Instruction(adjoint_type(raw_gate), un_adjointed_instruction.target))
end

function _translate_parameters(py_params, parameter_names::Vector{String}, ::Val{true})
    isempty(py_params) && return Float64[]
    param_names          = isempty(parameter_names) ? fill("", length(py_params)) : parameter_names
    length(param_names) != length(py_params) && throw(ErrorException("Parameter names list must be equal to number of operation parameters"))
    parameters = map(zip(param_names, py_params)) do (param_name, param)
        # PennyLane passes any non-keyword argument in the operation.parameters list.
        # In some cases, like the unitary gate or qml.QubitChannel (Kraus noise), these
        # parameter can be matrices. Braket only supports parameterization of numeric parameters
        # (so far, these are all angle parameters), so non-numeric parameters are handled
        # separately.
        param_name != "" && return BraketStateVector.Braket.FreeParameter(param_name)
        pyisinstance(param, pennylane.numpy.tensor) && return pyconvert(Array, param.numpy())
        return pyconvert(Float64, param)
    end
    return parameters
end

for (conv_fn, jl_typ, str) in ((:pennylane_convert_X, :(Observables.X), "x"),
                               (:pennylane_convert_Y, :(Observables.Y), "y"),
                               (:pennylane_convert_Z, :(Observables.Z), "z"),
                               (:pennylane_convert_I, :(Observables.I), "i"),
                               (:pennylane_convert_H, :(Observables.H), "h"),
                              )
    @eval begin
        $conv_fn(::Type{Observables.Observable}, x::Py) = PythonCall.pyconvert_return($jl_typ())
        $conv_fn(::Type{Tuple{IRObservable, Vector{Int}}}, x::Py) = PythonCall.pyconvert_return(($str, pyconvert(Vector{Int}, x.wires)))
    end
end
function pennylane_convert_Hermitian(::Type{Observables.Observable}, o::Py)
    return PythonCall.pyconvert_return(BraketStateVector.Braket.Observables.HermitianObservable(pyconvert(Matrix{ComplexF64}, o.parameters[0])))
end
function pennylane_convert_Hermitian(::Type{Tuple{IRObservable, Vector{Int}}}, o::Py)
    mat = BraketStateVector.Braket.complex_matrix_to_ir(pyconvert(Matrix{ComplexF64}, o.parameters[0]))
    return PythonCall.pyconvert_return((mat, pyconvert(Vector{Int}, o.wires)))
end

function pennylane_convert_Tensor(::Type{Observables.Observable}, o::Py)
    return PythonCall.pyconvert_return(Observables.TensorProduct([pyconvert(Observables.Observable, o.obs)]))
end
function pennylane_convert_Tensor(::Type{Tuple{IRObservable, Vector{Int}}}, o::Py)
    raw_obs       = [ pyconvert(Tuple{IRObservable, Vector{Int}}, f) for f in o.obs ]
    tensor_ops    = convert(IRObservable, reduce(vcat, [o[1] for o in raw_obs]))
    tensor_qubits = reduce(vcat, [o[2] for o in raw_obs])
    return PythonCall.pyconvert_return((tensor_ops, tensor_qubits))
end

for (ir_typ, conv_fn, braket_name) in ((:(BraketStateVector.Braket.IR.Expectation), :pennylane_convert_ExpectationMP, "expectation"),
                                       (:(BraketStateVector.Braket.IR.Variance), :pennylane_convert_VarianceMP, "variance"),
                                       (:(BraketStateVector.Braket.IR.Sample), :pennylane_convert_SampleMP, "sample"),
                                      )
    @eval begin
        function $conv_fn(::Type{AbstractProgramResult}, o::Py)
            ir_obs, ir_qubits = pyconvert(Tuple{IRObservable, Vector{Int}}, o.obs)
            return PythonCall.pyconvert_return($ir_typ(ir_obs, ir_qubits, $braket_name))  
        end
    end
end

function pennylane_convert_QuantumScript(::Type{Program}, o)
    instructions   = [pyconvert(Instruction, i) for i in o.operations]
    results_list   = [pyconvert(AbstractProgramResult, i) for i in o.measurements]
    instr_qubits   = mapreduce(ix->ix.target, union, instructions)
    result_qubits  = mapreduce(ix->hasproperty(ix, :targets) ? ix.targets : Set{Int}(), union, results_list, init=Set{Int}())
    all_qubits     = union(result_qubits, instr_qubits) 
    missing_qubits = union(setdiff(result_qubits, instr_qubits), setdiff(0:maximum(all_qubits), instr_qubits))
    for q in missing_qubits
        push!(instructions, Instruction(Braket.I(), q))
    end
    prog         = Program(BraketStateVector.Braket.header_dict[Program], instructions, results_list, [])
    return PythonCall.pyconvert_return(prog)
end

function _translate_parameter_names(n_params::Int, param_index::Int, trainable_indices::Set{Int}, use_unique_parameters::Bool, ::Val{false})
    n_params == 0 && return String[], param_index
    parameter_names = fill("", n_params)
    ix = 1
    for p in 1:n_params
        if param_index ∈ trainable_indices || use_unique_parameters
            parameter_names[ix] = "p_$param_index"
            ix += 1
        end
        param_index += 1
    end
    return parameter_names, param_index
end

function _translate_parameter_names(n_params::Int, param_index::Int, trainable_indices::Set{Int}, use_unique_parameters::Bool, ::Val{true})
    return fill("", n_params), param_index + n_params
end