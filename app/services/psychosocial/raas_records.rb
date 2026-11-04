# Registros da RAAS do mês de um CAPS que vão à remessa e à ficha espelho
# (ADR 0049; contrato §6, P14, P15, P37; plano, Desvios 7, 9 e 10).
#
# Entram os registros da janela da matrícula (MonthProblems.in_window: os de
# meses depois do `closed_on` ficam fora, P37) que têm ao menos uma ação RAAS
# (`raas_psi`) não cancelada do CAPS no mês com a matrícula como participante
# (P14: registro sem ação fica fora da remessa e das fichas; ações BPA-C/BPA-I
# vão pelo 22, nunca pela RAAS). Os dados: a foto (`snapshot`) do registro
# fechado ou exportado; do registro aberto, os dados ao vivo na mesma forma
# (MonthlyRecords.snapshot, com o telefone do par validado). Nada daqui vai a
# log, evento ou erro.
module Psychosocial
  module RaasRecords
    Entry = Data.define(:record, :data, :actions) do
      # LGPD: a foto e as ações nunca aparecem em inspect/log.
      def inspect = "#<Psychosocial::RaasRecords::Entry record=#{record.id} actions=#{actions.size}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect) # Data#pretty_print ignora o inspect
    end

    module_function

    # month: dia 1º. status: só os registros nesse estado (a remessa: `closed`);
    # lock: trava os registros (FOR UPDATE, a remessa). -> [Entry] na ordem de
    # criação dos registros.
    def for(unit:, month:, enrollment_id: nil, status: nil, lock: false)
      records = MonthProblems.in_window(unit.id, month)
      records = records.where(psychosocial_enrollment_id: enrollment_id) if enrollment_id
      records = records.where(status: status) if status
      records = records.lock("FOR UPDATE OF psychosocial_monthly_records") if lock
      records = records.includes(psychosocial_enrollment: :patient).order(:created_at, :id).to_a
      actions = actions_by_enrollment(unit.id, month, records.map(&:psychosocial_enrollment_id))
      records = records.select { |record| actions.key?(record.psychosocial_enrollment_id) }
      contacts = live_contacts(records)

      records.map do |record|
        Entry.new(record: record, data: data(record, contacts), actions: actions.fetch(record.psychosocial_enrollment_id))
      end
    end

    # Registro do writer da remessa: a foto, o id do registro e as ações.
    def file_record(entry) = entry.data.merge("record_id" => entry.record.id, "actions" => entry.actions)

    # A foto do registro fechado; do aberto, os dados ao vivo na mesma forma (JSON).
    def data(record, contacts)
      return record.snapshot unless record.status == "open"

      phone = contacts[record.psychosocial_enrollment.patient_id]&.phone
      JSON.parse(MonthlyRecords.snapshot(record, phone: phone).to_json)
    end

    def live_contacts(records)
      open = records.select { |record| record.status == "open" }
      open.empty? ? {} : Billing::PatientContact.for(open.map { |record| record.psychosocial_enrollment.patient_id })
    end

    # { enrollment_id => [ação] } das ações RAAS não canceladas do CAPS no mês,
    # pela hora: data local, código, CBO gravado, CNS do profissional,
    # quantidade, local e autorização. Nunca notas nem o motivo do cancelamento.
    def actions_by_enrollment(health_unit_id, month, enrollment_ids)
      return {} if enrollment_ids.empty?

      PsychosocialActionParticipant.joins(:psychosocial_action)
                                   .where(psychosocial_enrollment_id: enrollment_ids,
                                          psychosocial_actions: { health_unit_id: health_unit_id, month: month, cancelled_at: nil,
                                                                  instrument: "raas_psi" })
                                   .includes(psychosocial_action: { professional_user: :professional }).to_a
                                   .sort_by { |p| [ p.psychosocial_action.performed_at, p.psychosocial_action_id ] }
                                   .group_by(&:psychosocial_enrollment_id)
                                   .transform_values { |participants| participants.map { |p| action(p.psychosocial_action) } }
    end

    def action(action)
      { "action_id" => action.id, "performed_on" => action.performed_at.in_time_zone.to_date.iso8601, "sigtap_code" => action.sigtap_code,
        "cbo_code" => action.cbo_code, "professional_cns" => Billing::Staff.cns(action.professional_user), "quantity" => action.quantity,
        "place" => action.place, "authorization_number" => action.authorization_number }
    end

    private_class_method :data, :live_contacts, :actions_by_enrollment, :action
  end
end
