using Test, CUDA, Braket, BraketStateVector, DataStructures

import Braket: Instruction

funcs = CUDA.functional() ? (identity, cu) : (identity,)

@testset "State vector simulator" begin
    for f in funcs
        @testset "Simple circuits $instructions" for (instructions, qubit_count, state_vector, probability_amplitudes) in [
            ([Instruction(H(), [0])], 1, [0.70710678, 0.70710678], [0.5, 0.5]),
            ([Instruction(X(), [0])], 1, [0, 1], [0, 1]),
            ([Instruction(X(), [0])], 2, [0, 0, 1, 0], [0, 0, 1, 0]),
            ([Instruction(Y(), [0])], 1, [0, im], [0, 1]),
            ([Instruction(X(), [0]), Instruction(X(), [1])], 2, [0, 0, 0, 1], [0, 0, 0, 1]),
            ([Instruction(X(), [0]), Instruction(Z(), [0])], 1, [0, -1], [0, 1]),
            ([Instruction(X(), [0]), Instruction(CNot(), [0, 1])], 2, [0, 0, 0, 1], [0, 0, 0, 1]),
            ([Instruction(X(), [0]), Instruction(CY(), [0, 1])], 2, [0, 0, 0, im], [0, 0, 0, 1]),
            ([Instruction(X(), [0]), Instruction(CZ(), [0, 1])], 2, [0, 0, 1, 0], [0, 0, 1, 0]),
            ([Instruction(X(), [0]), Instruction(Swap(), [0, 1])], 2, [0, 1, 0, 0], [0, 1, 0, 0]),
            ([Instruction(X(), [0]), Instruction(ISwap(), [0, 1])], 2, [0, im, 0, 0], [0, 1, 0, 0]),
            (
                [Instruction(X(), [0]), Instruction(Swap(), [0, 2])],
                3,
                [0, 1, 0, 0, 0, 0, 0, 0],
                [0, 1, 0, 0, 0, 0, 0, 0],
            ),
            ([Instruction(X(), [0]), Instruction(S(), [0])], 1, [0, im], [0, 1]),
            ([Instruction(X(), [0]), Instruction(Si(), [0])], 1, [0, -im], [0, 1]),
            (
                [Instruction(X(), [0]), Instruction(T(), [0])],
                1,
                [0, 0.70710678 + 0.70710678*im],
                [0, 1],
            ),
            (
                [Instruction(X(), [0]), Instruction(Ti(), [0])],
                1,
                [0, 0.70710678 - 0.70710678*im],
                [0, 1],
            ),
            (
                [Instruction(V(), [0])],
                1,
                [0.5 + 0.5*im, 0.5 - 0.5*im],
                [0.5, 0.5],
            ),
            (
                [Instruction(Vi(), [0])],
                1,
                [0.5 - 0.5*im, 0.5 + 0.5*im],
                [0.5, 0.5],
            ),
            ([Instruction(I(), [0])], 1, [1, 0], [1, 0]),
            ([Instruction(Unitary([0 1; 1 0]), [0])], 1, [0, 1], [0, 1]),
            (
                [Instruction(X(), [0]), Instruction(PhaseShift(0.15), [0])],
                1,
                [0, 0.98877108 + 0.14943813*im],
                [0, 1],
            ),
            (
                [
                    Instruction(X(), [0]),
                    Instruction(X(), [1]),
                    Instruction(CPhaseShift(0.15), [0, 1]),
                ],
                2,
                [0, 0, 0, 0.98877108 + 0.14943813*im],
                [0, 0, 0, 1],
            ),
            (
                [Instruction(CPhaseShift00(0.15), [0, 1]) ],
                2,
                [0.98877108 + 0.14943813*im, 0, 0, 0],
                [1, 0, 0, 0],
            ),
            (
                [Instruction(X(), [1]), Instruction(CPhaseShift01(0.15), [0, 1])],
                2,
                [0, 0.98877108 + 0.14943813*im, 0, 0],
                [0, 1, 0, 0],
            ),
            (
                [Instruction(X(), [0]), Instruction(CPhaseShift10(0.15), [0, 1])],
                2,
                [0, 0, 0.98877108 + 0.14943813*im, 0],
                [0, 0, 1, 0],
            ),
            ([Instruction(Rx(0.15), [0])], 1, [0.99718882, -0.07492971*im], [0.99438554, 0.00561446]),
            (
                [Instruction(X(), [0]), Instruction(Ry(0.15), [0])],
                1,
                [-0.07492971, 0.99718882],
                [0.00561446, 0.99438554],
            ),
            (
                [Instruction(H(), [0]), Instruction(Rz(0.15), [0])],
                1,
                [0.70511898 - 0.0529833*im, 0.70511898 + 0.0529833*im],
                [0.5, 0.5],
            ),
            (
                [Instruction(X(), [0]), Instruction(PSwap(0.15), [0, 1])],
                2,
                [0, 0.98877108 + 0.14943813*im, 0, 0],
                [0, 1, 0, 0],
            ),
            (
                [Instruction(X(), [0]), Instruction(XY(0.15), [0, 1])],
                2,
                [0, 0.07492971*im, 0.99718882, 0],
                [0, 0.00561446, 0.99438554, 0],
            ),
            (
                [Instruction(XX(0.3), [0, 1])],
                2,
                [0.98877108, 0, 0, -0.14943813*im],
                [0.97766824, 0, 0, 0.02233176],
            ),
            (
                [Instruction(YY(0.3), [0, 1]) ],
                2,
                [0.98877108, 0, 0, 0.14943813*im],
                [0.97766824, 0, 0, 0.02233176],
            ),
            ([Instruction(ZZ(0.15), [0, 1])], 2, [0.99718882 - 0.07492971*im, 0, 0, 0], [1, 0, 0, 0]),
            (
                [
                    Instruction(X(), [0]),
                    Instruction(X(), [1]),
                    Instruction(CCNot(), [0, 1, 2]),
                ],
                3,
                [0, 0, 0, 0, 0, 0, 0, 1],
                [0, 0, 0, 0, 0, 0, 0, 1],
            ),
            (
                [
                    Instruction(X(), [0]),
                    Instruction(X(), [1]),
                    Instruction(CSwap(), [0, 1, 2]),
                ],
                3,
                [0, 0, 0, 0, 0, 1, 0, 0],
                [0, 0, 0, 0, 0, 1, 0, 0],
            ),
        ]
            simulation = f(StateVectorSimulator(qubit_count, 0))
            simulation = evolve!(simulation, instructions)
            @test state_vector ≈ collect(simulation.state_vector)
            @test probability_amplitudes ≈ BraketStateVector.probabilities(simulation)
        end
        @testset "Apply observables $obs" for (obs, equivalent_gates, qubit_count) in [
            ([(Braket.Observables.X(), [0])], [Instruction(H(), [0])], 1),
            ([(Braket.Observables.Z(), [0])], Instruction[], 1),
            ([(Braket.Observables.I(), [0])], Instruction[], 1),
            ([(Braket.Observables.X(), [0]), (Braket.Observables.Z(), [3]), (Braket.Observables.H(), [2])], [Instruction(H(), [0]), Instruction(Ry(-π/4), [2])], 5),
            ([(Braket.Observables.TensorProduct([Braket.Observables.X(), Braket.Observables.Z(), Braket.Observables.H(), Braket.Observables.I()]), (0, 3, 2, 1))], [Instruction(H(), [0]), Instruction(Ry(-π/4), [2])], 5),
            ([(Braket.Observables.X(), [0, 1])], [Instruction(H(), [0]), Instruction(H(), [1])], 2),
            ([(Braket.Observables.Z(), [0, 1])], Instruction[], 2),
            ([(Braket.Observables.I(), [0, 1])], Instruction[], 2),
            ([(Braket.Observables.TensorProduct([Braket.Observables.I(), Braket.Observables.Z()]), (2, 0))], Instruction[], 3),
            ([(Braket.Observables.TensorProduct([Braket.Observables.X(), Braket.Observables.Z()]), (2, 0))], [Instruction(H(), [2])], 3,),
        ]
            sim_observables = f(StateVectorSimulator(qubit_count, 0))
            sim_observables = BraketStateVector.apply_observables!(sim_observables, obs)
            sim_gates = f(StateVectorSimulator(qubit_count, 0))
            sim_gates = BraketStateVector.evolve!(sim_gates, equivalent_gates)
            @test BraketStateVector.state_with_observables(sim_observables) ≈ sim_gates.state_vector
        end
        @testset "Apply observables fails at second call" begin
            simulation = f(StateVectorSimulator(4, 0))
            simulation = BraketStateVector.apply_observables!(simulation, [(Braket.Observables.X(), [0])])
            @test_throws ErrorException BraketStateVector.apply_observables!(simulation, [(Braket.Observables.X(), [0])])
        end
        @testset "state_with_observables fails before any observables are applied" begin
            simulation = f(StateVectorSimulator(4, 0))
            @test_throws ErrorException BraketStateVector.state_with_observables(simulation)
        end
        @testset "QFT simulation" begin
            function qft_circuit_operations(qubit_count::Int)
                qft_ops = Instruction[]
                for target_qubit in 0:qubit_count-1
                    angle = π / 2
                    push!(qft_ops, Instruction(H(), [target_qubit]))
                    for control_qubit in target_qubit + 1:qubit_count-1
                        push!(qft_ops, Instruction(CPhaseShift(angle), [control_qubit, target_qubit]))
                        angle /= 2
                    end
                end
                return qft_ops
            end

            qubit_count = 16
            simulation = f(StateVectorSimulator(qubit_count, 0))
            operations = qft_circuit_operations(qubit_count)
            simulation = BraketStateVector.evolve!(simulation, operations)
            @test BraketStateVector.probabilities(simulation) ≈ fill(1.0/(2^qubit_count), 2^qubit_count)
        end
        @testset "samples" begin
            simulation = f(StateVectorSimulator(2, 10000))
            simulation = BraketStateVector.evolve!(simulation, [Instruction(H(), [0]), Instruction(CNot(), [0, 1])])
            samples = counter(BraketStateVector.samples(simulation))

            @test qubit_count(simulation) == 2
            @test collect(keys(samples)) == [0, 3]
            @test 0.4 < samples[0] / (samples[0] + samples[3]) < 0.6
            @test 0.4 < samples[3] / (samples[0] + samples[3]) < 0.6
            @test samples[0] + samples[3] == 10000
        end
    end
end
