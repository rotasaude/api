# Situação vacinal materializada (ADR 0047; Desvios 10 e 11): uma linha por
# paciente × série em vaccination_statuses, cópia recalculável do
# Vaccination::Schedule (DELETE + INSERT; linhas not_applicable não são
# gravadas). Recalculada na dose, no cancelamento, na transcrição, na
# conferência, na caderneta de quem ainda não tem conferência e pelo job
# diário. Antes de recalcular, grava a conferência `born_after_go_live`
# (sem autor nem sala) quando o paciente nasceu em ou depois de
# vaccination_settings.go_live_on — uma vez por paciente.
#
# `go_live`: a data já lida por quem recalcula muitos pacientes (o job diário
# lê uma vez por execução); sem ela (`:load`), lida de VaccinationSetting.
#
# Recálculos do mesmo paciente são serializados por uma trava consultiva de
# transação (a chave é um hash do id; nada do paciente no SQL).
module Vaccination
  module Statuses
    PREGNANCY_TEMPLATE = "pregnancy_c3".freeze

    module_function

    def refresh!(patient, today: Time.zone.today, go_live: :load)
      birth = birth_date(patient)
      VaccinationStatus.transaction(requires_new: true) do
        lock!(patient.id)
        record_born_after_go_live!(patient.id, birth, go_live == :load ? VaccinationSetting.current.go_live_on : go_live)
        VaccinationStatus.where(patient_id: patient.id).delete_all
        next unless birth

        checked = checked?(patient.id)
        doses = doses_of(patient.id)
        items = Schedule.call(birth_date: birth, sex: patient.sex, pregnant_since: pregnant_since(patient), doses: doses,
                              checked: checked, today: today, calendar: Calendar.current)
        rows = rows_for(patient.id, items, age_months: Calendar.completed_months(birth, today), checked: checked, today: today)
        VaccinationStatus.insert_all!(rows) if rows.any?
      end
      nil
    end

    def checked?(patient_id) = VaccinationRecordCheck.where(patient_id: patient_id).exists?

    # Doses ATIVAS na forma do Schedule (data no fuso da cidade).
    def doses_of(patient_id)
      Immunization.active.where(patient_id: patient_id).order(:applied_at, :id)
                  .pluck(:id, :immunobiological_code, :dose_code, :applied_at)
                  .map { |id, code, dose_code, at| { id: id, code: code, dose_code: dose_code, on: at.in_time_zone.to_date } }
    end

    # Início estimado da gestação: a DUM (anchor_date) da inscrição ATIVA na
    # linha de pré-natal (pregnancy_c3); nil sem inscrição ou sem DUM.
    def pregnant_since(patient)
      CareLineEnrollment.active_enrollments.joins(:care_line)
                        .where(patient_id: patient.id, care_lines: { template_key: PREGNANCY_TEMPLATE })
                        .order(:enrolled_at, :id).filter_map(&:anchor_on).last
    end

    def birth_date(patient)
      patient.birth_date.present? ? Date.iso8601(patient.birth_date) : nil
    rescue Date::Error
      nil
    end


    def record_born_after_go_live!(patient_id, birth, go_live)
      return unless birth && go_live && birth >= go_live
      return if VaccinationRecordCheck.where(patient_id: patient_id, mode: "born_after_go_live").exists?

      VaccinationRecordCheck.create!(patient_id: patient_id, mode: "born_after_go_live", checked_at: Time.current)
    end

    # Uma linha por série: a situação da primeira dose pendente aplicável; sem
    # pendente, `complete` se houve dose; sem nada aplicável, nenhuma linha.
    def rows_for(patient_id, items, age_months:, checked:, today:)
      items.group_by(&:series).filter_map do |series, list|
        complete = list.select { |item| item.status == "complete" }
        nextone = list.find { |item| !%w[complete not_applicable].include?(item.status) }
        current = nextone || complete.last
        next unless current

        { patient_id: patient_id, series: series, immunobiological_code: current.immunobiological_code,
          status: nextone ? nextone.status : "complete", next_dose_code: nextone&.dose_code, due_on: nextone&.due_on,
          doses_applied: complete.size + list.count { |item| item.status != "complete" && item.applied_id },
          age_months: age_months, checked: checked, computed_on: today }
      end
    end

    def lock!(patient_id)
      key = Digest::SHA256.hexdigest("vaccination_statuses:#{patient_id}")[0, 15].to_i(16)
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{key})")
    end

    private_class_method :record_born_after_go_live!, :rows_for, :lock!
  end
end
