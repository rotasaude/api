# Crítica recalculada com o cadastro do momento (plano do módulo 22, Desvio
# 7): CBO vazio é procurado de novo no vínculo; CNS, sexo, nascimento, nome e
# CNES relidos. `call` grava (fechamento); `outcome` só lê (pendências).
# `cache`: um Billing::SigtapCache por chamada de fechamento/recálculo (I2).
module Billing
  module Recalculate
    module_function

    def call(procedure, establishment:, cache: SigtapCache.new)
      cbo = procedure.cbo_code || Staff.cbo_for(procedure.professional_user, establishment)
      result = outcome(procedure, establishment: establishment, cbo: cbo, cache: cache)
      changes = { instrument: result.instrument, billable: result.billable, blocking_reasons: result.reasons,
                  sigtap_competence: result.sigtap_competence, sigtap_fallback: result.fallback }
      changes[:cbo_code] = cbo if procedure.cbo_code.nil? && cbo
      procedure.update!(changes) if changes.any? { |key, value| procedure.public_send(key) != value }
      result
    end

    def outcome(procedure, establishment:, cbo: procedure.cbo_code || Staff.cbo_for(procedure.professional_user, establishment),
                cache: SigtapCache.new)
      Critic.call(Critic::Facts.new(establishment: establishment, sigtap_code: procedure.sigtap_code, performed_on: procedure.performed_on,
                                    cbo_code: cbo, professional_cns: Staff.cns(procedure.professional_user), cid10: procedure.cid10,
                                    patient: procedure.patient), closing: true, cache: cache)
    end
  end
end
