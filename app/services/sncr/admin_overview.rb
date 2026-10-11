# Painel do SNCR do admin municipal (ADR 0034; spec §7; contrato §6). Só
# leitura; o saldo do modo corrente (simulado ou real); nada de número SNCR,
# CPF ou inscrição. Nenhuma coluna cifrada é lida.
module Sncr
  module AdminOverview
    module_function

    def call(simulated:)
      free = SncrNumber.available.where(simulated: simulated).group(:user_id, :kind).count
      last = SncrNumberBatch.where(simulated: simulated).group(:user_id).maximum(:requested_at)
      professionals = Professional.joins(:user).where(users: { deactivated_at: nil }, council: StartRequest::COUNCILS)
                                  .order(:professional_name, :user_id).map do |professional|
        rce = free.fetch([ professional.user_id, "rce" ], 0)
        ret = free.fetch([ professional.user_id, "ret" ], 0)
        { user_id: professional.user_id, name: professional.professional_name, rce_free: rce, ret_free: ret,
          low: rce < Stock::LOW_THRESHOLD || ret < Stock::LOW_THRESHOLD, last_request_at: last[professional.user_id]&.iso8601 }
      end
      { professionals: professionals, simulated: simulated }
    end
  end
end
