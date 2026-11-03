# ESAVI a partir da dose (ADR 0047, Desvio 17; contrato §15 V12): abre a
# notificação `esavi` do módulo 25 pelo único caminho de nascimento
# (Surveillance::CreateNotification), com origin "manual", a dose de origem, a
# unidade da dose (a da sala; a transcrição também tem a da sala) e a suspeita
# agora. Já há notificação para o paciente × doença (o 25 deixa uma aberta, e
# a janela de repetição de uma fechada) → devolve a existente, sem criar outra.
# O interruptor `surveillance` e a equipe da sala são do controlador (lidos
# fora da transação). Dose cancelada não notifica. Nada de vacina, lote ou
# dose em log, evento ou Result: só ids.
module Vaccination
  module NotifyEsavi
    DISEASE_CODE = "esavi".freeze

    module_function

    # -> Result.ok(notification_id:, created:) | fail(:immunization_cancelled)
    #    | fail(:disease_unavailable) (a lista nacional não traz a esavi na data)
    def call(immunization:, by:, now: Time.current)
      return Result.fail(:immunization_cancelled) if immunization.cancelled?

      disease = Surveillance::Diseases.find(DISEASE_CODE, today: now.to_date)
      return Result.fail(:disease_unavailable) unless disease

      result = Surveillance::CreateNotification.call(patient: immunization.patient, disease: disease, origin: "manual",
                                                     unit: immunization.health_unit, suspected_at: now, by: by,
                                                     immunization: immunization)
      return Result.ok(notification_id: result.payload.fetch(:notification).id, created: true) if result.ok?
      return Result.ok(notification_id: result.details.fetch(:notification_id), created: false) if result.reason == :already_notified

      result
    end
  end
end
