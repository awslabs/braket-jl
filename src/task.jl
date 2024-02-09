using Distributed, Statistics, Logging, UUIDs, HTTP
using LinearAlgebra: eigvals

const DEFAULT_SHOTS = 1000
const DEFAULT_RESULTS_POLL_TIMEOUT = 432000
const DEFAULT_RESULTS_POLL_INTERVAL = 1

"""
    AwsQuantumTask

Struct representing a task run on an Amazon-managed device.
"""
mutable struct AwsQuantumTask
    arn::String 
    client_token::String
    poll_timeout_seconds::Int
    poll_interval_seconds::Int
    _future::Union{Future, Nothing}
    _config::AbstractAWSConfig
    _metadata::Dict{String, Any}
    _logger::AbstractLogger
    _result::Union{Nothing, AbstractQuantumTaskResult}
    function AwsQuantumTask(arn::String;
                   client_token::String=string(uuid1()),
                   poll_timeout_seconds::Int=DEFAULT_RESULTS_POLL_TIMEOUT,
                   poll_interval_seconds::Int=DEFAULT_RESULTS_POLL_INTERVAL,
                   logger=global_logger(),
                   config::AWSConfig=global_aws_config())
        new(arn, client_token, poll_timeout_seconds, poll_interval_seconds, nothing, config, Dict(), logger, nothing)
    end
end
Base.show(io::IO, t::AwsQuantumTask) = println(io, "AwsQuantumTask(\"id/taskArn\":\"$(arn(t))\")")
id(t::AwsQuantumTask) = t.arn
"""
    arn(t::AwsQuantumTask) -> String

Returns the ARN identifying the task `t`. This ARN can be used to 
reconstruct the task after the session that launched it has exited.
"""
arn(t::AwsQuantumTask) = t.arn

function AwsQuantumTask(args::NamedTuple)
    action       = args[:action]
    client_token = args[:client_token]
    device_arn   = args[:device_arn]
    s3_bucket    = args[:outputS3Bucket]
    s3_key_prefix = args[:outputS3KeyPrefix]
    shots        = args[:shots]
    extra_opts   = args[:extra_opts]
    config       = args[:config]
    job_token    = get(ENV, "AMZN_BRAKET_JOB_TOKEN", nothing)
    !isnothing(job_token) && merge!(extra_opts, Dict("jobToken"=>job_token))
    timeout_seconds  = get(args, :poll_timeout_seconds, DEFAULT_RESULTS_POLL_TIMEOUT)
    interval_seconds = get(args, :poll_interval_seconds, DEFAULT_RESULTS_POLL_INTERVAL)
    merge!(AWS.AWSServices.braket.service_specific_headers, AWS.LittleDict("Braket-Trackers"=>string(length(GlobalTrackerContext[]))))
    response         = BRAKET.create_quantum_task(action, client_token, device_arn, s3_bucket, s3_key_prefix, shots, extra_opts, aws_config=config)
    pop!(AWS.AWSServices.braket.service_specific_headers, "Braket-Trackers")
    broadcast_event!(TaskCreationEvent(response["quantumTaskArn"], shots, !isnothing(job_token), device_arn))
    return AwsQuantumTask(response["quantumTaskArn"]; client_token=client_token, poll_timeout_seconds=timeout_seconds, poll_interval_seconds=interval_seconds, config=config)
end

function default_task_bucket()
    haskey(ENV, "AMZN_BRAKET_TASK_RESULTS_S3_URI") && return parse_s3_uri(ENV["AMZN_BRAKET_TASK_RESULTS_S3_URI"])
    return (default_bucket(), "tasks")
end

"""
    AwsQuantumTask(device_arn::String, task_spec; kwargs...)

Launches an [`AwsQuantumTask`](@ref) based on `task_spec` on the device associated with `device_arn`.

`task_spec` must be one of:
  - `OpenQASMProgram`
  - `BlackbirdProgram`
  - `Problem`
  - `Program`
  - [`Circuit`](@ref)
  - `AHSProgram`
  - [`AnalogHamiltonianSimulation`](@ref)

Valid `kwargs` are:
  - `s3_destination_folder::Tuple{String, String}`, with default value `default_task_bucket()`.
  - `shots::Int` - the number of shots to run, with default value $DEFAULT_SHOTS. Value must be between `0` and `MAX_SHOTS` for the specific device.
  - `device_params::Dict{String, Any}` - device specific parameters. Currently only used for DWave devices and simulators.
  - `disable_qubit_rewiring::Bool` - whether to allow qubit rewiring in the compilation stage. Default is `false`.
  - `poll_timeout_seconds::Int` - maximum number of seconds to wait while polling for results. Default: $DEFAULT_RESULTS_POLL_TIMEOUT
  - `poll_interval_seconds::Int` - default number of seconds to wait between attempts while polling for results. Default: $DEFAULT_RESULTS_POLL_INTERVAL
  - `tags::Dict{String, String}` - tags for the `AwsQuantumTask`
  - `inputs::Dict{String, Float64}` - input values for any free parameters in the `task_spec`
"""
function AwsQuantumTask(device_arn::String,
                        task_spec::Union{AbstractProgram, Circuit, AnalogHamiltonianSimulation};
                        s3_destination_folder::Tuple{String, String}=default_task_bucket(),
                        shots::Int=DEFAULT_SHOTS,
                        device_params::Dict{String,<:Any}=Dict{String,Any}(),
                        disable_qubit_rewiring::Bool=false,
                        poll_timeout_seconds::Int=DEFAULT_RESULTS_POLL_TIMEOUT,
                        poll_interval_seconds::Int=DEFAULT_RESULTS_POLL_INTERVAL,
                        tags::Dict{String, String}=Dict{String, String}(),
                        inputs::Dict{String,Float64}=Dict{String, Float64}(),
                        config::AbstractAWSConfig=global_aws_config())
    args = prepare_task_input(task_spec, device_arn, s3_destination_folder, shots, device_params, disable_qubit_rewiring, tags=tags, poll_timeout_seconds=poll_timeout_seconds, poll_interval_seconds=poll_interval_seconds, inputs=inputs, config=config)
    return AwsQuantumTask(args)
end

function _create_annealing_device_params(device_params::Dict{Symbol, Any}, device_arn::String)
    if occursin("Advantage", device_arn)
        T = DwaveAdvantageDeviceParameters
        TL = DwaveAdvantageDeviceLevelParameters
    elseif occursin("2000Q", device_arn)
        T = Dwave2000QDeviceParameters
        TL = Dwave2000QDeviceLevelParameters
    else
        throw(ArgumentError("Amazon Braket could not find a device with the ARN: $device_arn. To continue, make sure that the value of the device_arn parameter corresponds to a valid QPU."))
    end
    device_level_parameters = haskey(device_params, :deviceLevelParameters) ? convert(Dict{Symbol, Any}, device_params[:deviceLevelParameters]) : convert(Dict{Symbol, Any}, get(device_params, :providerLevelParameters, Dict{Symbol, Any}()))
    device_level_parameters = delete!(device_level_parameters, :braketSchemaHeader) # in case of old version
    defaults = merge(Dict(zip(fieldnames(TL), fill(nothing, nfields(TL)))), StructTypes.defaults(TL))
    sym_dlps = Dict(zip(Symbol.(keys(device_level_parameters)), values(device_level_parameters)))
    dlps     = merge(defaults, sym_dlps)
    dlps[:braketSchemaHeader] = Braket.header_dict[TL]
    device_level_parameters = StructTypes.constructfrom(TL, dlps)
    return T(Braket.header_dict[T], device_level_parameters) 
end
_create_annealing_device_params(device_params, device_arn) = _create_annealing_device_params(convert(Dict{Symbol, Any}, JSON3.read(JSON3.write(device_params))), device_arn)

function _create_common_params(device_arn::String, s3_destination_folder::Tuple{String, String}, shots::Int; kwargs...)
    timeout_seconds  = get(kwargs, :poll_timeout_seconds, DEFAULT_RESULTS_POLL_TIMEOUT)
    interval_seconds = get(kwargs, :poll_interval_seconds, DEFAULT_RESULTS_POLL_INTERVAL)
    config           = get(kwargs, :config, global_aws_config())
    return (device_arn=device_arn, outputS3Bucket=s3_destination_folder[1],  outputS3KeyPrefix=s3_destination_folder[2], shots=shots, poll_timeout_seconds=timeout_seconds, poll_interval_seconds=interval_seconds, config=config)
end

function _device_parameters_from_dict(device_parameters::Dict{String,<:Any}, device_arn::String, paradigm_parameters::GateModelParameters)
    error_mitigation = get(device_parameters, "errorMitigation", nothing)
    processed_em = error_mitigation isa ErrorMitigation ? ir(error_mitigation) : error_mitigation
    occursin("ionq", device_arn) && return IonqDeviceParameters(header_dict[IonqDeviceParameters], paradigm_parameters, processed_em)
    occursin("rigetti", device_arn) && return RigettiDeviceParameters(header_dict[RigettiDeviceParameters], paradigm_parameters)
    occursin("oqc", device_arn) && return OqcDeviceParameters(header_dict[OqcDeviceParameters], paradigm_parameters)
    return GateModelSimulatorDeviceParameters(header_dict[GateModelSimulatorDeviceParameters], paradigm_parameters)
end

function prepare_task_input(problem::Problem, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Union{Dict{String,<:Any}, DwaveDeviceParameters, DwaveAdvantageDeviceParameters, Dwave2000QDeviceParameters}, disable_qubit_rewiring::Bool=false; kwargs...)
    device_parameters = _create_annealing_device_params(device_params, device_arn)
    common = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    client_token = string(uuid1())
    action     = JSON3.write(problem)
    dev_params = JSON3.write(device_parameters)
    tags       = get(kwargs, :tags, Dict{String,String}())
    extra_opts = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

function prepare_task_input(ahs::AnalogHamiltonianSimulation, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String,<:Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    return prepare_task_input(ir(ahs), device_arn, s3_folder, shots, device_params, disable_qubit_rewiring; kwargs...)
end

function prepare_task_input(program::OpenQasmProgram, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String,<:Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    common       = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    client_token = string(uuid1())
    tags         = get(kwargs, :tags, Dict{String,String}())
    device_parameters = !isempty(device_params) ? _device_parameters_from_dict(device_params, device_arn, GateModelParameters(header_dict[GateModelParameters], 0, false)) : Dict{String, Any}() 
    dev_params   = JSON3.write(device_parameters)
    extra_opts   = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    
    inputs = get(kwargs, :inputs, Dict{String, Float64}())
    if !isempty(inputs)
        prog_inputs = isnothing(program.inputs) ? Dict{String, Float64}() : program.inputs
        inputs_merged = merge(prog_inputs, inputs)
        program_ = OpenQasmProgram(program.braketSchemaHeader, program.source, inputs_merged)
        action   = JSON3.write(program_)
    else
        action   = JSON3.write(program)
    end
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

function prepare_task_input(program::Union{AHSProgram, BlackbirdProgram}, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String, Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    device_parameters = Dict{String, Any}() # not currently used
    common = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    client_token = string(uuid1())
    action     = JSON3.write(program)
    dev_params = JSON3.write(device_parameters)
    tags       = get(kwargs, :tags, Dict{String,String}())
    extra_opts = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

function prepare_task_input(circuit::Circuit, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String, Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    validate_circuit_and_shots(circuit, shots)
    common = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    paradigm_parameters = GateModelParameters(header_dict[GateModelParameters], qubit_count(circuit), disable_qubit_rewiring)
    qubit_reference_type = VIRTUAL
    if disable_qubit_rewiring || Instruction(StartVerbatimBox()) in circuit.instructions
        #|| any(instruction.operator isa PulseGate for instruction in circuit.instructions)
        qubit_reference_type = QubitReferenceType.PHYSICAL
    end
    serialization_properties = OpenQASMSerializationProperties(qubit_reference_type=qubit_reference_type)
    oq3_program = ir(circuit, Val(:OpenQASM), serialization_properties=serialization_properties)
    inputs = get(kwargs, :inputs, Dict{String, Float64}())
    program_inputs = isnothing(oq3_program.inputs) ? Dict{String, Float64}() : oq3_program.inputs
    inputs_merged = !isempty(inputs) ? merge(program_inputs, inputs) : oq3_program.inputs
    oq3_program = OpenQasmProgram(oq3_program.braketSchemaHeader, oq3_program.source, inputs_merged)

    device_parameters = _device_parameters_from_dict(device_params, device_arn, paradigm_parameters) 
    client_token = string(uuid1())
    action       = JSON3.write(oq3_program)
    dev_params   = JSON3.write(device_parameters)
    tags         = get(kwargs, :tags, Dict{String,String}())
    extra_opts   = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

function prepare_task_input(circuit::Program, device_arn::String, s3_folder::Tuple{String, String}, shots::Int, device_params::Dict{String, Any}, disable_qubit_rewiring::Bool=false; kwargs...)
    common = _create_common_params(device_arn, s3_folder, shots; kwargs...)
    paradigm_parameters = GateModelParameters(header_dict[GateModelParameters], qubit_count(circuit), disable_qubit_rewiring)
    client_token = string(uuid1())
    action       = JSON3.write(circuit)
    device_parameters = _device_parameters_from_dict(device_params, device_arn, paradigm_parameters) 
    dev_params   = JSON3.write(device_parameters)
    tags         = get(kwargs, :tags, Dict{String,String}())
    extra_opts   = Dict("deviceParameters"=>dev_params, "tags"=>tags)
    return merge((action=action, client_token=client_token, extra_opts=extra_opts), common)
end

function queue_position(t::AwsQuantumTask)
    response = metadata(t)["queueInfo"]
    queue_type = QueueType(response["queuePriority"])
    queue_position = get(response, "position", "None") == "None" ? "" : response["position"]
    message = get(response, "message", "")
    return QuantumTaskQueueInfo(queue_type, queue_position, message)
end

"""
    cancel(t::AwsQuantumTask)

Cancels the task `t`.
"""
function cancel(t::AwsQuantumTask)
    #!isnothing(t._future) && cancel(t.future)
    resp = BRAKET.cancel_quantum_task(t.client_token, HTTP.escapeuri(t.arn), aws_config=t._config)
    broadcast_event!(TaskStatusEvent(t.arn, resp["cancellationStatus"]))
    return
end

"""
    metadata(t::AwsQuantumTask, ::Val{false})
    metadata(t::AwsQuantumTask, ::Val{true})

Fetch metadata for task `t`.
If the second argument is `::Val{true}`, use previously cached
metadata, if available, otherwise fetch it from the Braket service.
If the second argument is `::Val{false}` (default), do not use previously cached
metadata, and fetch fresh metadata from the Braket service.
"""
function metadata(t::AwsQuantumTask, ::Val{false})
    uri = HTTP.escapeuri(t.arn) * "?additionalAttributeNames=QueueInfo"
    resp = BRAKET.get_quantum_task(uri)
    payload = parse(resp)
    broadcast_event!(TaskStatusEvent(t.arn, payload["status"]))
    return payload
end
metadata(t::AwsQuantumTask, ::Val{true})  = !isempty(t._metadata) ? t._metadata : metadata(t, Val(false))
metadata(t::AwsQuantumTask) = metadata(t, Val(false))

"""
    state(t::AwsQuantumTask, ::Val{false}) -> String
    state(t::AwsQuantumTask, ::Val{true}) -> String
    state(t::AwsQuantumTask) -> String

Fetch the state for task `t`.
Possible states are `"CANCELLED"`, `"FAILED"`, `"COMPLETED"`, `"QUEUED"`, and `"RUNNING"`.
If the second argument is `::Val{true}`, use previously cached
metadata, if available, otherwise fetch it from the Braket service.
If the second argument is `::Val{false}` (default), do not use previously cached
metadata, and fetch fresh metadata from the Braket service.
"""
function state(t::AwsQuantumTask, ::Val{false})
    mtd = metadata(t, Val(false))
    status = mtd["status"]
    if status ∈ ["FAILED", "CANCELLED"]
        with_logger(t._logger) do
            @warn "Task is in terminal state $status and no result is available."
            if status == "FAILED"
                failure_reason = get(mtd, "failureReason", "unknown")
                @warn "Task failure reason is: $failure_reason."
            end
        end
    end
    return status
end

function state(t::AwsQuantumTask, ::Val{true})
    mtd = metadata(t, Val(true))
    status = mtd["status"]
    return status
end

state(t::AwsQuantumTask) = state(t, Val(false))

"""
    result(t::AwsQuantumTask)

Fetches the result of task `t`, if available. Blocks until a result
is available, in which case the result is returned, or the task enters a
terminal state without a result (`"FAILED"` or `"CANCELLED"`) or exceeds its
its polling timeout (set at task creation), in which case `nothing` is returned.
"""
function result(t::AwsQuantumTask)
    if !isnothing(t._result) || (!isempty(t._metadata) && state(t, Val(true)) ∈ ["FAILED", "CANCELLED"])
        return t._result
    end
    if !isempty(t._metadata) && state(t, Val(true)) ∈ ["COMPLETED"]
        return _download_result(t)
    end
    start = time()
    while state(t, Val(true)) ∉ ["FAILED", "CANCELLED", "COMPLETED"] && time() - start < t.poll_timeout_seconds
        sleep(t.poll_interval_seconds)
    end
    state(t, Val(false)) == "COMPLETED" && return _download_result(t)
    return nothing
end

retrieve_result_from_s3(bucket::String, location::String) = String(AWSS3.s3_get(bucket, location))

function _download_result(t::AwsQuantumTask)
    current_meta = metadata(t, Val(true))
    result_string = retrieve_result_from_s3(current_meta["outputS3Bucket"], current_meta["outputS3Directory"] * "/results.json")
    res = parse_raw_schema(result_string)
    t._result = format_result(res)
    execution_duration = nothing
    try
        execution_duration = res.additionalMetadata.simulatorMetadata.executionDuration
    catch
        @warn "execution duration not found"
    end
    broadcast_event!(TaskCompletionEvent(t.arn, state(t, Val(true)), execution_duration))
    return t._result
end

Base.:(==)(t1::AwsQuantumTask, t2::AwsQuantumTask) = (id(t1) == id(t2))
Base.hash(t::AwsQuantumTask, h::UInt) = hash(id(t), h)

function count_tasks_with_status(device_arn::String, status::Vector{String}; token=nothing)
    token_ = token
    task_count = 0
    for status_ in status
        filters = [Dict("name"=>"status", "operator"=>"EQUAL", "values"=>[status_]), Dict("name"=>"deviceArn", "operator"=>"EQUAL", "values"=>[device_arn])]
        response = BRAKET.search_quantum_tasks(filters)
        token_ = response["nextToken"]
        status_count = length(response["quantumTasks"])
        task_count += length(response["quantumTasks"])
    end
    return task_count
end
count_tasks_with_status(device_arn::String, status::String) = count_tasks_with_status(device_arn, [status])

Base.show(io::IO, r::GateModelQuantumTaskResult) = println(io, "GateModelQuantumTaskResult")
Base.show(io::IO, r::PhotonicModelQuantumTaskResult) = println(io, "PhotonicModelQuantumTaskResult")
Base.show(io::IO, r::AnnealingQuantumTaskResult) = println(io, "AnnealingQuantumTaskResult")
Base.show(io::IO, r::AnalogHamiltonianSimulationQuantumTaskResult) = println(io, "AnalogHamiltonianSimulationQuantumTaskResult")

# Unicode representation of 0 is \u0030 and of 1 is \u0031
# UInt8 representation of 0 is 0x30 and of 1 is 0x31
# Int64 representation of 0 is 48 and of 1 is 49
to_bitstr(m::Vector{Int}) = String(UInt8.(48 .+ m))
function measurement_counts(measurements::Vector{Vector{Int}})
    # do this first as converting to bitstring is expensive
    vec_ctr = counter(m for m in measurements)
    str_ctr = Accumulator{String, Int}()
    for (k, v) in vec_ctr
        str_ctr[to_bitstr(k)] = v
    end
    return str_ctr
end
measurement_probabilities(measurement_counts::Accumulator, shots::Int) = Dict{String, Float64}(key=>count/shots for (key, count) in measurement_counts)
function _measurements(probs::Dict{String, Float64}, shots::Int)
    measurements = Vector{Vector{Int}}(undef, shots)
    m_ix = 1
    for (bitstring, prob) in probs
        int_list    = [tryparse(Int, string(b)) for b in bitstring]
        n_shots     = convert(Int, round(prob*shots))
        measurement = [int_list for ii in 1:n_shots]
        measurements[m_ix:m_ix+shots-1] = measurement[:]
        m_ix += shots
    end
    return measurements
end

function _unsafe_indexin(targets::NTuple{N, Int}, measured_qubits::NTuple{M, Int})::Vector{Int} where {N,M}
    function _index_finder(t::Int, measured_qubits::NTuple{M, Int}) where {M}
        for mqi in 1:M
            @inbounds(t == measured_qubits[mqi]) && return mqi 
        end
    end
    return SVector{N, Int}(_index_finder(t, measured_qubits) for t in targets)
end

function _selected_measurements(measurements::Matrix{Int}, measured_qubits::NTuple{M, Int}, targets::NTuple{N, Int}) where {N, M}
    cols = if targets == measured_qubits
        SVector{N, Int}(ix+1 for ix in measured_qubits)
    else
        _unsafe_indexin(targets, measured_qubits)
    end
    return (@inbounds(view(m, cols)) for m in eachrow(measurements))
end
function _selected_measurements(measurements::Vector{Vector{Int}}, measured_qubits::NTuple{M, Int}, targets::NTuple{N, Int}) where {N, M}
    cols = if targets == measured_qubits
        SVector{N, Int}(ix+1 for ix in measured_qubits)
    else
        _unsafe_indexin(targets, measured_qubits)
    end
    return (@inbounds(view(m, cols)) for m in measurements)
end
_selected_measurements(measurements, measured_qubits::NTuple{M, Int}, targets::Nothing) where {M} = _selected_measurements(measurements, measured_qubits, measured_qubits)

function _to_base_10(m, nq::Int)
    ix = 0
    for q in 0:nq-1
        @inbounds ix |= m[q+1] << (nq - 1 - q)
    end
    return ix + 1
end


function _measurements_base_10(measurements::Matrix{Int}, nq::Int)
    return (_to_base_10(m, nq) for m in eachrow(measurements))
end

function _measurements_base_10(measurements::T, nq::Int) where {T}
    return (_to_base_10(m, nq) for m in measurements)
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::O, targets::Tuple{Int}, ::Type{IR.Sample}) where {O<:Observables.StandardObservable, M}
    m = _selected_measurements(measurements, measured_qubits, targets)
    return (-2.0 * first(m_) + 1.0 for m_ in m)
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::TensorProduct{O}, targets::NTuple{T, Int}, ::Type{IR.Sample}) where {O<:Observables.StandardObservable, M, T}
    _measurements = _selected_measurements(measurements, measured_qubits, targets)
    ixs = _measurements_base_10(_measurements, T)
    evs = PauliEigenvalues(Val(T), observable.coefficient)
    return (evs[ix] for ix in ixs)
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::TensorProduct{O}, targets::NTuple{T, Int}, ::Type{IR.Sample}) where {O<:Observables.Observable, M, T}
    _measurements = _selected_measurements(measurements, measured_qubits, targets)
    ixs = _measurements_base_10(_measurements, T)
    evs = eigvals(observable)
    return (evs[ix] for ix in ixs)
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::O, targets::NTuple{T, Int}, ::Type{IR.Sample}) where {O<:Observables.Observable, M, T}
    _measurements = _selected_measurements(measurements, measured_qubits, targets)
    ixs = _measurements_base_10(_measurements, T)
    evs = eigvals(observable)
    return (evs[ix] for ix in ixs)
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::O, targets::NTuple{T, Int}, ::Type{IR.Variance}) where {O<:Observables.Observable, M, T}
    samples = _calculate_for_targets(measurements, measured_qubits, observable, targets, IR.Sample)
    return var(samples)
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::O, targets::NTuple{T, Int}, ::Type{IR.Expectation}) where {O<:Observables.Observable, M, T}
    samples = _calculate_for_targets(measurements, measured_qubits, observable, targets, IR.Sample)
    return mean(samples)
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::O, targets::Nothing, ::Type{T}) where {T, M, O<:Observables.Observable}
    return [first(_calculate_for_targets(measurements, measured_qubits, observable, (q,), T)) for q in measured_qubits]
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::O, targets::Nothing, ::Type{IR.Sample}) where {M, O<:Observables.Observable}
    return [collect(_calculate_for_targets(measurements, measured_qubits, observable, (q,), IR.Sample)) for q in measured_qubits]
end

function _calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, targets::NTuple{T, Int}, ::Type{IR.Probability}) where {M, T}
    _measurements = _selected_measurements(measurements, measured_qubits, targets)
    ixs   = _measurements_base_10(_measurements, T)
    count = counter(ixs)
    shots = size(measurements, 1)
    probabilities = zeros(Float64, 2^T)
    for (b, v) in count
        probabilities[b] = v / shots
    end
    return probabilities
end
_calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, targets::Nothing, ::Type{IR.Probability}) where {M} = _calculate_for_targets(measurements, measured_qubits, measured_qubits, IR.Probability)

_calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, targets::Vector{Int}, ::Type{IR.Probability}) where {M} = _calculate_for_targets(measurements, measured_qubits, tuple(targets...), IR.Probability)
_calculate_for_targets(measurements, measured_qubits::NTuple{M, Int}, observable::O, targets::Vector{Int}, ::Type{T}) where {M, O<:Observables.Observable, T} = _calculate_for_targets(measurements, measured_qubits, observable, tuple(targets...), T)

function _reconstruct_and_compute_value(rt::IR.Probability, measurements::Vector{Vector{Int}}, measured_qubits::NTuple{M, Int})::ResultTypeValue where {M}
    val = _calculate_for_targets(measurements, measured_qubits, rt.targets, IR.Probability)
    return ResultTypeValue(rt, val)
end

function _reconstruct_and_compute_value(rt::T, measurements::Vector{Vector{Int}}, measured_qubits::NTuple{M, Int})::ResultTypeValue where {T<:Union{IR.Expectation, IR.Variance}, M}
    obs::Observables.Observable = StructTypes.constructfrom(Observables.Observable, rt.observable)
    val = _calculate_for_targets(measurements, measured_qubits, obs, rt.targets, T)
    return ResultTypeValue(rt, val)
end
function _reconstruct_and_compute_value(rt::IR.Sample, measurements::Vector{Vector{Int}}, measured_qubits::NTuple{M, Int})::ResultTypeValue where {M}
    obs = StructTypes.constructfrom(Observables.Observable, rt.observable)
    val = _calculate_for_targets(measurements, measured_qubits, obs, rt.targets, IR.Sample)
    return ResultTypeValue(rt, collect(val))
end

function calculate_result_types(action::IR.Program, measurements::Vector{Vector{Int}}, measured_qubits::NTuple{M, Int})::Vector{ResultTypeValue} where {M}
    any(rt.type ∉ ["probability", "sample", "expectation", "variance"] for rt in action.results) && throw(ErrorException("unknown result type."))
    result_types = Vector{ResultTypeValue}(undef, length(action.results))
    for r_ix in 1:length(action.results)
        result_types[r_ix] = _reconstruct_and_compute_value(action.results[r_ix], measurements, measured_qubits)
    end
    return result_types
end
calculate_result_types(action, measurements::Vector{Vector{Int}}, measured_qubits)::Vector{ResultTypeValue} = ResultTypeValue[]

function computational_basis_sampling(::Type{GateModelQuantumTaskResult}, r::GateModelTaskResult)
    task_mtd = r.taskMetadata
    addl_mtd = r.additionalMetadata
    if !isnothing(r.measurements)
        measurements = convert(Vector{Vector{Int}}, r.measurements)
        m_counts     = measurement_counts(measurements)
        m_probs      = measurement_probabilities(m_counts, task_mtd.shots)
        measurements_copied_from_device = true
        m_counts_copied_from_device     = true
        m_probs_copied_from_device      = true
    elseif !isnothing(r.measurementProbabilities)
        shots        = task_mtd.shots
        m_probs      = r.measurementProbabilities
        measurements = _measurements(m_probs, shots)
        m_counts     = measurement_counts(measurements)
        measurements_copied_from_device = false
        m_counts_copied_from_device     = false
        m_probs_copied_from_device      = true
    else
        throw(ErrorException("One of `measurements` or `measurementProbabilities` must be populated in the result object."))
    end
    measured_qubits = ntuple(ix->r.measuredQubits[ix], length(r.measuredQubits))
    if isnothing(r.resultTypes) || isempty(r.resultTypes)
        result_types = calculate_result_types(addl_mtd.action, measurements, measured_qubits)::Vector{ResultTypeValue}
    else
        if !isempty(r.resultTypes) && !isnothing(r.resultTypes[1])
            false_action = IR.Program(header_dict[IR.Program], [], [rt.type for rt in r.resultTypes], [])
            result_types = calculate_result_types(false_action, measurements, measured_qubits)::Vector{ResultTypeValue}
        else
            result_types = r.resultTypes::Vector{ResultTypeValue}
        end
    end
    vals = [rt.value for rt in result_types]
    return GateModelQuantumTaskResult(task_mtd, addl_mtd, result_types, vals, measurements, r.measuredQubits, m_counts, m_probs, measurements_copied_from_device, m_counts_copied_from_device, m_probs_copied_from_device, nothing)
end

function from_dict(::Type{GateModelQuantumTaskResult}, r::GateModelTaskResult)
    task_mtd = r.taskMetadata
    addi_mtd = r.additionalMetadata
    rts      = r.resultTypes
    vals = map(rts) do rt
        !(rt.type isa IR.Amplitude) && return rt.value
        val_keys = string.(keys(rt.value))
        val_vals = [complex(v...) for v in values(rt.value)]
        return Dict{String, ComplexF64}(zip(val_keys, val_vals))
    end
    return GateModelQuantumTaskResult(task_mtd, addi_mtd, rts, vals, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)
end

function format_result(r::GateModelTaskResult)
    if r.taskMetadata.shots > 0
        return computational_basis_sampling(GateModelQuantumTaskResult, r)
    else
        return from_dict(GateModelQuantumTaskResult, r)
    end
end

function format_result(r::AnnealingTaskResult)
    solutions = convert(Vector{Vector{Int}}, r.solutions)
    values    = convert(Vector{Float64}, r.values)
    solution_counts = isnothing(r.solutionCounts) ? ones(Int, length(solutions)) : convert(Vector{Int}, r.solutionCounts)
    n_solutions  = length(solutions)
    n_variables  = length(solutions[1])
    record_array = AxisArray(hcat(solutions, values, solution_counts), 1:n_solutions, [:solution, :value, :solution_count])
    problem_type = JSON3.read("\"$(r.additionalMetadata.action.type)\"", ProblemType)
    return AnnealingQuantumTaskResult(record_array, n_variables, problem_type, r.taskMetadata, r.additionalMetadata) 
end

function format_result(r::PhotonicModelTaskResult)
    task_mtd     = r.taskMetadata
    addi_mtd     = r.additionalMetadata
    measurements = !isnothing(r.measurements) ? convert(Vector{Vector{Vector{Int}}}, r.measurements) : nothing
    return PhotonicModelQuantumTaskResult(task_mtd, addi_mtd, measurements)
end

function get_measurements(r::AnalogHamiltonianSimulationTaskResult)
    meas = map(r.measurements) do m
        status        = AnalogHamiltonianSimulationShotStatusDict[lowercase(m.shotMetadata.shotStatus)]
        pre_sequence  = !isnothing(m.shotResult.preSequence) ? convert(Array{Int}, m.shotResult.preSequence) : nothing
        post_sequence = !isnothing(m.shotResult.postSequence) ? convert(Array{Int}, m.shotResult.postSequence) : nothing
        return ShotResult(status, pre_sequence, post_sequence)
    end
    return meas
end

function format_result(r::AnalogHamiltonianSimulationTaskResult)
    isnothing(r.measurements) && return AnalogHamiltonianSimulationQuantumTaskResult(r.taskMetadata, nothing)
    return AnalogHamiltonianSimulationQuantumTaskResult(r.taskMetadata, get_measurements(r))
end
