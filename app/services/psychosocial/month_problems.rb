# Pendências da RAAS do mês de um CAPS (ADR 0049; contrato §6, P14, P24, P37;
# plano, Desvio 7; ruling action_out_of_rule). Lidas, nunca gravadas.
#
# Registros considerados: os do CAPS no mês, menos os de meses DEPOIS do
# `closed_on` da matrícula (P37: ficam fora da crítica, das pendências e do
# fechamento). Por registro, na ordem de Catalog::PROBLEM_CODES:
#   patient_cns_missing — paciente sem CNS;
#   phone_missing — sem telefone de 10–11 dígitos no par validado (Billing::PatientContact);
#   homeless_missing — situação de rua do mês não informada;
#   professional_cns_missing — profissional de uma ação do mês sem CNS;
#   professional_not_in_cnes — profissional de uma ação (com CNS) sem vínculo no
#     retrato do CNES com o CNES do CAPS e o CBO gravado na ação (CnesCheck);
#   cid_missing — matrícula sem CID principal;
#   action_out_of_rule — ação que ActionRules.recheck recusa hoje (instrumento,
#     CBO gravado, quantidade e autorização na SIGTAP da competência; nada de
#     matrícula, mês ou data);
#   night_stay_open — permanência aberta da matrícula com noite no mês (P14).
# Avisos (Catalog::WARNING_CODES; não bloqueiam): no_actions — nenhuma ação
# RAAS (raas_psi) não cancelada do CAPS no mês com a matrícula como
# participante (a ação BPA vai pelo 22: o registro só com ela fica fora da
# remessa e das fichas). actions_count e a crítica contam toda ação.
#
# -> { counts: { records:, open:, closed:, exported:, with_problems:, with_warnings:, actions: },
#      records: [ { record:, patient:, actions_count:, problems: [String], warnings: [String] } ] }
module Psychosocial
  module MonthProblems
    module_function

    def for(health_unit:, month:, today: Time.zone.today)
      month = month.to_date.beginning_of_month
      records = in_window(health_unit.id, month).includes(psychosocial_enrollment: :patient).order(:created_at, :id).to_a
      enrollment_ids = records.map(&:psychosocial_enrollment_id)
      links, raas_enrollment_ids = action_links(health_unit.id, month, enrollment_ids)
      action_codes = action_codes(links.values.flatten.uniq, health_unit)
      contacts = Billing::PatientContact.for(records.map { |r| r.psychosocial_enrollment.patient_id })
      staying = staying_enrollment_ids(health_unit.id, enrollment_ids, month, today)

      entries = records.map do |record|
        enrollment = record.psychosocial_enrollment
        action_ids = links.fetch(enrollment.id, [])
        codes = Set.new
        codes << "patient_cns_missing" if enrollment.patient.cns.blank?
        codes << "phone_missing" if contacts[enrollment.patient_id]&.phone.blank?
        codes << "homeless_missing" if record.homeless.nil?
        codes << "cid_missing" if enrollment.cid_main.blank?
        action_ids.each { |id| codes.merge(action_codes.fetch(id)) }
        codes << "night_stay_open" if staying.include?(enrollment.id)
        codes << "no_actions" unless raas_enrollment_ids.include?(enrollment.id)
        { record: record, patient: enrollment.patient, actions_count: action_ids.size,
          problems: Catalog::PROBLEM_CODES.select { |code| codes.include?(code) },
          warnings: Catalog::WARNING_CODES.select { |code| codes.include?(code) } }
      end
      { counts: counts(entries, links), records: entries }
    end

    # Registros do CAPS no mês dentro da janela da matrícula (P37).
    def in_window(health_unit_id, month)
      PsychosocialMonthlyRecord.joins(:psychosocial_enrollment)
                               .where(health_unit_id: health_unit_id, month: month.to_date.beginning_of_month)
                               .where("psychosocial_enrollments.closed_on IS NULL OR psychosocial_monthly_records.month <= psychosocial_enrollments.closed_on")
    end

    # [ { enrollment_id => [action_id] } das ações não canceladas do CAPS no mês,
    #   Set das matrículas com alguma delas RAAS (`raas_psi`) ] — o aviso
    # no_actions olha só a RAAS (fix round 1 da Task 10): registro só com
    # BPA-C/BPA-I fica fora da remessa e das fichas, então também avisa.
    def action_links(health_unit_id, month, enrollment_ids)
      return [ {}, Set.new ] if enrollment_ids.empty?

      rows = PsychosocialActionParticipant.joins(:psychosocial_action)
                                          .where(psychosocial_enrollment_id: enrollment_ids,
                                                 psychosocial_actions: { health_unit_id: health_unit_id, month: month, cancelled_at: nil })
                                          .pluck(:psychosocial_enrollment_id, :psychosocial_action_id, "psychosocial_actions.instrument")
      links = rows.each_with_object(Hash.new { |h, k| h[k] = [] }) { |(enrollment_id, action_id, _), out| out[enrollment_id] << action_id }
      [ links, rows.select { |(_, _, instrument)| instrument == "raas_psi" }.to_set(&:first) ]
    end

    # { action_id => [código] } — profissional (CNS, CNES) e a releitura da SIGTAP.
    # Participantes pré-carregados (o recheck lê a coleção).
    def action_codes(action_ids, unit)
      sigtap = Billing::SigtapCache.new
      cnes = {}
      PsychosocialAction.where(id: action_ids).includes(:psychosocial_action_participants, professional_user: :professional)
                        .to_h do |action|
        cns = Billing::Staff.cns(action.professional_user)
        codes = []
        if cns.nil?
          codes << "professional_cns_missing"
        elsif !CnesCheck.bonded?(cns: cns, cbo: action.cbo_code, cnes: unit.cnes, cache: cnes)
          codes << "professional_not_in_cnes"
        end
        codes << "action_out_of_rule" if ActionRules.recheck(action, cache: sigtap).any?
        [ action.id, codes ]
      end
    end

    # Matrículas com permanência aberta no CAPS que tem noite no mês: a primeira
    # noite até o fim do mês e o fim provável (o previsto, ou hoje, se já
    # passou: a saída ainda vai gravar essas noites) depois do início do mês.
    def staying_enrollment_ids(health_unit_id, enrollment_ids, month, today)
      return Set.new if enrollment_ids.empty?

      PsychosocialNightStay.open_stays.where(health_unit_id: health_unit_id, psychosocial_enrollment_id: enrollment_ids).to_a.select do |stay|
        from = stay.started_at.in_time_zone.to_date
        to = [ stay.expected_end_at.in_time_zone.to_date, today, from + 1 ].max
        from <= month.end_of_month && to > month
      end.to_set(&:psychosocial_enrollment_id)
    end

    def counts(entries, links)
      statuses = entries.map { |e| e[:record].status }.tally
      { records: entries.size, open: statuses.fetch("open", 0), closed: statuses.fetch("closed", 0), exported: statuses.fetch("exported", 0),
        with_problems: entries.count { |e| e[:problems].any? }, with_warnings: entries.count { |e| e[:warnings].any? },
        actions: links.values.flatten.uniq.size }
    end

    private_class_method :action_links, :action_codes, :staying_enrollment_ids, :counts
  end
end
