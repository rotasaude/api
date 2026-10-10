# app/commands/patients/apply_medication_event.rb
# Único caminho de escrita da lista de medicamentos em uso (ADR 0033; spec
# §5; Invariantes). Grava o evento ANTES de mudar o estado — o trigger
# patient_medications_guard exige um evento da mesma transação com o mesmo
# status. Quem chama abriu a transação e travou o paciente
# (ClinicalDocuments::Issue, PatientMedicationsController).
#   add        — sem igual: incluir; igual suspenso: reativar (com a posologia
#                nova); igual ativo: on_active :change → changed (ou nada, se
#                igual), :fail → already_active
#   suspend    — ativo → suspenso
#   reactivate — suspenso → ativo (already_active se já há um ativo igual)
# "Igual" = mesmo item do catálogo; no texto livre, o texto sem acento, caixa
# nem espaço extra (o texto é cifrado: compara em Ruby, com o paciente travado).
module Patients
  module ApplyMedicationEvent
    ACTIONS = %w[add suspend reactivate].freeze
    SOURCES = %i[consultation addendum document].freeze
    MAX_SUMMARY = 200

    module_function

    def call(patient:, action:, by:, source:, origin: "prescription", catalog_item: nil, free_text: nil,
             dosage_summary: nil, continuous: true, medication: nil, on_active: :change, on: Time.zone.today)
      link = source.slice(*SOURCES).compact
      raise ArgumentError, "source: consulta, adendo OU documento" unless link.size == 1 && source.keys.size == 1
      return Result.fail(:invalid_medication) unless ACTIONS.include?(action.to_s)
      return Result.fail(:invalid_medication) if medication && medication.patient_id != patient.id

      summary = dosage_summary.to_s.squish.first(MAX_SUMMARY).presence
      origin_data = { by: by, link: link }
      case action.to_s
      when "add" then add(patient, catalog_item, free_text, summary, continuous, origin, on_active, on, origin_data)
      when "suspend"
        return Result.fail(:invalid_medication) unless medication&.lock!&.active?

        write(medication, "suspended", { status: "suspended" }, origin_data)
      when "reactivate"
        return Result.fail(:invalid_medication) unless medication

        medication.lock!
        return Result.fail(:already_active) if medication.active? || same(patient, medication).any?(&:active?)

        write(medication, "reactivated", { status: "active" }, origin_data)
      end
    end

    def add(patient, catalog_item, free_text, summary, continuous, origin, on_active, on, origin_data)
      text = catalog_item ? nil : free_text.to_s.squish
      return Result.fail(:invalid_medication) if catalog_item.nil? && text.blank?

      existing = catalog_item ? PatientMedication.where(patient_id: patient.id, catalog_item_id: catalog_item.id).lock.to_a : same_text(patient, text)
      active = existing.find(&:active?)
      if active
        return Result.fail(:already_active) if on_active == :fail
        return Result.ok(medication: active, event: nil) if active.dosage_summary == summary && active.continuous == continuous

        return write(active, "changed", { dosage_summary: summary, continuous: continuous }, origin_data)
      end
      suspended = existing.max_by(&:updated_at)
      return write(suspended, "reactivated", { status: "active", dosage_summary: summary, continuous: continuous }, origin_data) if suspended

      medication = PatientMedication.new(id: SecureRandom.uuid, patient: patient, catalog_item_id: catalog_item&.id,
                                         catmat_code: catalog_item&.catmat_code, free_text: text,
                                         label: catalog_item ? catalog_item.label : text, dosage_summary: summary,
                                         continuous: continuous, status: "active", origin: origin, started_on: on)
      write(medication, "added", {}, origin_data)
    end

    def same(patient, medication)
      return PatientMedication.where(patient_id: patient.id, catalog_item_id: medication.catalog_item_id).where.not(id: medication.id).to_a if medication.catalog_item_id

      same_text(patient, medication.free_text).reject { |row| row.id == medication.id }
    end

    def same_text(patient, text)
      key = normalize(text)
      PatientMedication.where(patient_id: patient.id, catalog_item_id: nil).lock.to_a.select { |row| normalize(row.free_text) == key }
    end

    def normalize(text) = I18n.transliterate(text.to_s).downcase.squish

    def write(medication, kind, attrs, origin_data)
      medication.assign_attributes(attrs)
      link = origin_data[:link]
      event = PatientMedicationEvent.create!(
        patient_medication_id: medication.id, kind: kind, consultation_id: link[:consultation]&.id,
        addendum_id: link[:addendum]&.id, clinical_document_id: link[:document]&.id, user: origin_data[:by],
        status_after: medication.status, dosage_summary: medication.dosage_summary
      )
      medication.save!
      ids = { document_id: link[:document]&.id, consultation_id: link[:consultation]&.id, addendum_id: link[:addendum]&.id }.compact
      DomainEvents.publish("patient_medication.changed", patient_medication_id: medication.id, kind: kind, **ids)
      Result.ok(medication: medication, event: event)
    end
    private_class_method :add, :same, :same_text, :normalize, :write
  end
end
