# Trechos de frota do TFD ligados aos passageiros da viagem (plano, Desvio 13;
# preflight R9). Única porta do transporte para o TFD:
#   - complete!(trip): no fechamento da viagem (Transport::CloseTrip, na mesma
#     transação), marca `done` o trecho de frota de cada passageiro `boarded`;
#   - complete_passenger!(passenger): na correção no_show → boarded
#     (Transport::CorrectAttendance) de um passageiro com trecho ainda aberto.
# O corpo (Tfd::CompleteLeg, ajudas de custo e BPA) é da Task 11; até lá, as
# duas assinaturas existem e não fazem nada (complete! → [], complete_passenger! → nil).
module Tfd
  module FleetLegs
    module_function

    # -> [TfdLeg] completados (Task 11).
    def complete!(_trip) = []

    # -> TfdLeg completado | nil (Task 11).
    def complete_passenger!(_passenger) = nil
  end
end
