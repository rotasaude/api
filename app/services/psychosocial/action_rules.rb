# Crítica SIGTAP da ação do CAPS na hora (ADR 0049; plano, Desvios 1, 3, 4 e
# 5; contrato §4, P3, P23), sobre a SIGTAP da competência do mês LOCAL da ação
# (23:30 de 30/11 no fuso da cidade é novembro, mesmo sendo dezembro em UTC).
# Todos os problemas de uma vez, na ordem do contrato §4, cada um
# `{ error, path, participant_index? }` (o índice é o do corpo, 0-based):
#   instrument_mismatch (sigtap_code) — código fora da SIGTAP da competência,
#     ou sem instrumento 09/02/01;
#   cbo_incompatible (sigtap_code) — CBO do vínculo fora da lista do código
#     (lista vazia não restringe);
#   quantity_exceeded (quantity) — acima da quantidade máxima (nula = sem limite);
#   performed_in_future (performed_at);
#   month_closed (performed_at) — fechamento ativo do CAPS no mês;
#   enrollment_required (participants[i]) — participante com matrícula fechada,
#     de outro CAPS, inexistente ou iniciada depois da data (local) da ação
#     (ruling: started_on <= data da ação); (participants) — ação só RAAS-PSI sem
#     nenhum participante matriculado;
#   authorization_required (authorization_number) — atributo 036 sem número;
#   family_only_for_family_care (participants[i].family_name) — familiar sem
#     cadastro fora de `family_care_codes`;
#   bpa_i_single_patient (participants) — BPA-I sem exatamente um paciente;
#   caps_without_beds (sigtap_code) — o acolhimento noturno (`night_sigtap_code`)
#     num CAPS fora de NIGHT_MODALITIES (P61; options não o oferece).
# `recheck` relê uma ação gravada para a pendência `action_out_of_rule` do
# fechamento (ruling): só instrumento, CBO gravado, quantidade e autorização.
module Psychosocial
  module ActionRules
    AUTHORIZATION_ATTRIBUTE = "036".freeze

    module_function

    # input: { sigtap_code:, performed_at: (Time), quantity:, authorization_number:,
    #          participants: [ { enrollment_id:, enrollment: PsychosocialEnrollment | nil, patient_id:, family_name: } ] }
    # -> { instrument: String | nil, problems: [ { error:, path:, participant_index:? } ] }
    def problems(input, unit:, link:, now:, cache: Billing::SigtapCache.new)
      code = input.fetch(:sigtap_code)
      performed_at = input.fetch(:performed_at)
      participants = Array(input[:participants])
      month = month_of(performed_at)
      day = performed_at.in_time_zone.to_date
      release = cache.release(competence(month))
      procedure = release && cache.procedure(release, code)
      refused = participants.each_index.select { |i| participants[i][:enrollment_id] && !enrolled?(participants[i], unit, day) }
      enrolled = participants.any? { |p| enrolled?(p, unit, day) }
      instrument = procedure ? Instrument.for(cache.instruments(release, code), enrolled: enrolled) : :instrument_mismatch

      out = []
      out << problem("instrument_mismatch", "sigtap_code") if instrument == :instrument_mismatch
      out.concat(sigtap_problems(release, code, cbo: link.cbo_code, quantity: input[:quantity], cache: cache)) if procedure
      out << problem("performed_in_future", "performed_at") if performed_at > now
      out << problem("month_closed", "performed_at") if MonthlyRecords.closed?(unit.id, month)
      refused.each { |i| out << problem("enrollment_required", "participants[#{i}]", i) }
      out << problem("enrollment_required", "participants") if instrument == :enrollment_required && refused.empty?
      out << problem("authorization_required", "authorization_number") if procedure && authorization_missing?(release, code, input, cache)
      family_problems(code, participants).each { |problem| out << problem }
      out << problem("bpa_i_single_patient", "participants") if instrument == "bpa_i" && participants.count { |p| patient?(p) } != 1
      out << problem("caps_without_beds", "sigtap_code") if code == Raas.config.fetch("night_sigtap_code") && !unit.night_capable?

      { instrument: instrument.is_a?(String) ? instrument : nil, problems: out }
    end

    # Ação gravada (pendência action_out_of_rule do fechamento): instrumento,
    # CBO gravado na ação, quantidade e autorização na SIGTAP da competência do
    # mês da ação. Nada de matrícula, mês ou data. -> [ { error:, path: } ]
    # Lê `action.psychosocial_action_participants`: quem relê uma coleção
    # (fechamento do mês, Task 9) faz o preload dos participantes antes.
    def recheck(action, cache: Billing::SigtapCache.new)
      code = action.sigtap_code
      release = cache.release(competence(action.month))
      procedure = release && cache.procedure(release, code)
      return [ problem("instrument_mismatch", "sigtap_code") ] unless procedure

      enrolled = action.psychosocial_action_participants.any?(&:psychosocial_enrollment_id)
      out = []
      out << problem("instrument_mismatch", "sigtap_code") unless Instrument.for(cache.instruments(release, code), enrolled: enrolled) == action.instrument
      out.concat(sigtap_problems(release, code, cbo: action.cbo_code, quantity: action.quantity, cache: cache))
      if authorization_missing?(release, code, { authorization_number: action.authorization_number }, cache)
        out << problem("authorization_required", "authorization_number")
      end
      out
    end

    # Mês local da ação (dia 1º), no fuso da cidade.
    def month_of(time) = time.in_time_zone.to_date.beginning_of_month

    def competence(month) = month.strftime("%Y%m")

    def sigtap_problems(release, code, cbo:, quantity:, cache:)
      out = []
      cbos = cache.cbos(release, code)
      out << problem("cbo_incompatible", "sigtap_code") if cbos.any? && !cbos.include?(cbo)
      max = cache.max_quantity(release, code)
      out << problem("quantity_exceeded", "quantity") if max && quantity.to_i > max
      out
    end

    def authorization_missing?(release, code, input, cache)
      cache.attributes(release, code).include?(AUTHORIZATION_ATTRIBUTE) && input[:authorization_number].blank?
    end

    def family_problems(code, participants)
      return [] if Raas.config.fetch("family_care_codes").include?(code)

      participants.each_index.select { |i| participants[i][:family_name] }
                  .map { |i| problem("family_only_for_family_care", "participants[#{i}].family_name", i) }
    end

    # Matrícula aberta deste CAPS, iniciada até a data local da ação.
    def enrolled?(participant, unit, day)
      enrollment = participant[:enrollment]
      enrollment.present? && enrollment.health_unit_id == unit.id && enrollment.open? && enrollment.started_on <= day
    end

    def patient?(participant) = participant[:patient_id].present? || participant[:enrollment_id].present?

    def problem(error, path, index = nil)
      index.nil? ? { error: error, path: path } : { error: error, path: path, participant_index: index }
    end

    private_class_method :sigtap_problems, :authorization_missing?, :family_problems, :enrolled?, :patient?, :problem
  end
end
