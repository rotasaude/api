# POST /pharmacy/prescriptions/lookup (contrato §7, H3, H12): a receita para a
# farmácia, por `short_code` OU por `patient_id`, só no corpo JSON (qualquer
# chave na query → 422 invalid_request com o path). `pharmacist` ou
# `pharmacy_assistant` do local `unit` ativo de `location_id`; senão 403 sozinho.
#
#  - `short_code`: maiúsculas, com ou sem hífen/espaço, no formato do 19c
#    (senão 422 invalid_request, path short_code). Inexistente ou que não seja
#    receita (atestado, pedido de exame, REGISTRO DE NOTIFICAÇÃO) → 404
#    prescription_not_found. A receita cancelada vem com `cancelled: true`; a do
#    19c emitida em papel é dispensável como a digital.
#  - `patient_id`: as receitas do 19c e as externas do paciente nos últimos
#    LOOKUP_DAYS dias (dia da cidade), mais novas primeiro, até LOOKUP_MAX;
#    canceladas e vencidas vêm marcadas. Paciente inexistente → 422 patient_id.
#
# Trilha clinical_record.viewed (access "pharmacy"): UMA por paciente mostrado
# (nenhuma quando a busca não mostra receita nenhuma). 30 por minuto por usuário.
# O catálogo da plataforma é lido AQUI, fora de qualquer transação da cidade.
module Pharmacy
  class PrescriptionsController < BaseController
    rate_limit to: 30, within: 1.minute, only: :lookup, name: "pharmacy_prescription_lookup", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def lookup
      location = body_location_or_refuse
      return unless location
      return forbid unless dispenser_at?(location)
      return unless query_only!

      code = body_param("short_code")
      patient_id = body_param("patient_id")
      return render_refusal("patient_id") if !code.nil? && !patient_id.nil?
      return render_refusal("short_code") if code.nil? && patient_id.nil?

      prescriptions = code.nil? ? by_patient(patient_id) : by_code(code)
      return unless prescriptions

      patient = Patient.find(prescriptions.first.patient_id) if prescriptions.any?
      if patient
        Trail.person_viewed!(user: Current.user, patient_id: patient.id)
        settings = Settings.current
        today = Time.zone.today
        summaries = Dispensed.summaries(prescriptions)
        catalog = Json.catalog_for(prescriptions.flat_map { |prescription| prescription.items.filter_map(&:catalog_item_id) })
        views = prescriptions.map do |prescription|
          Json.prescription_view(prescription, patient: patient, summary: summaries.fetch(prescription.id), settings: settings, today: today,
                                               catalog: catalog)
        end
      end
      render json: { prescriptions: views || [] }
    end

    private

    # [Prescription] | nil (já respondeu).
    def by_code(raw)
      code = raw.is_a?(String) ? ClinicalDocuments::Codes.normalize(raw) : nil
      unless code
        render_refusal("short_code")
        return nil
      end

      document = ClinicalDocument.includes(:prescription_items, author_user: :professional).find_by(short_code: code, kind: "prescription")
      unless document
        render_error(:prescription_not_found, :not_found)
        return nil
      end

      settings = Settings.current
      [ Prescription.digital(document, catalog: Prescription.catalog_for(document.prescription_items.filter_map(&:medication_catalog_item_id)),
                                       settings: settings) ]
    end

    def by_patient(raw)
      patient = uuid?(raw) ? Patient.find_by(id: raw) : nil
      unless patient
        render_refusal("patient_id")
        return nil
      end

      Prescription.recent(patient_id: patient.id, since: Time.zone.today - Catalog::LOOKUP_DAYS, limit: Catalog::LOOKUP_MAX,
                          settings: Settings.current)
    end
  end
end
