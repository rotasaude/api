# POST /pharmacy/external_prescriptions (contrato §7, H3, H12): a receita de fora
# da rede digitada na farmácia. `location_id`, o paciente (`patient_id` OU
# `new_patient` + `duplicates_reviewed`), `prescriber`, `issued_on`,
# `notification_number`? e `items`, só no corpo JSON (qualquer chave na query →
# 422 invalid_request com o path). `pharmacist` ou `pharmacy_assistant` do local
# `unit` ativo; senão 403 sozinho. O item controlado só o farmacêutico registra
# (403 controlled_requires_pharmacist, sozinho).
#
# 201 com a <prescription_view> (`kind: "external"`, `short_code: null`), sem
# envelope. Todo 422 traz `problems` com todas as recusas; 409 para
# duplicate_suspected, cpf_taken e cns_taken. Trilha clinical_record.viewed da
# pessoa e evento external_prescription.recorded: do comando, na mesma transação
# da gravação. O catálogo da plataforma é lido AQUI, fora da transação.
module Pharmacy
  class ExternalPrescriptionsController < BaseController
    def create
      location = body_location_or_refuse
      return unless location
      return forbid unless dispenser_at?(location)
      return unless query_only!

      items = body_param("items")
      catalog = catalog_for(items)
      today = Time.zone.today
      settings = Settings.current
      result = RecordExternalPrescription.call(
        location: location, patient_id: body_param("patient_id"), new_patient: body_param("new_patient"),
        duplicates_reviewed: request.request_parameters.fetch("duplicates_reviewed", false), prescriber: body_param("prescriber"),
        issued_on: body_param("issued_on"), notification_number: body_param("notification_number"), items: items, by: Current.user,
        role: role_at(location), catalog: catalog, today: today, settings: settings
      )
      return render_failure(result) if result.failure?

      render json: view(result.payload.fetch(:external_prescription), result.payload.fetch(:patient), catalog, settings, today), status: :created
    end

    private

    # O papel que vale na gravação: o farmacêutico, se o usuário também é um.
    def role_at(location)
      Access.allowed?(user: Current.user, location: location, roles: %w[pharmacist]) ? "pharmacist" : "pharmacy_assistant"
    end

    # Itens do catálogo das linhas, numa consulta (só os ids que parecem uuid e só
    # as primeiras linhas: o resto o comando recusa por tamanho).
    def catalog_for(items)
      return {} unless items.is_a?(Array)

      ids = items.first(Catalog::MAX_EXTERNAL_ITEMS).filter_map { |row| row["catalog_item_id"] if row.is_a?(Hash) && uuid?(row["catalog_item_id"]) }
      Json.catalog_for(ids)
    end

    def view(record, patient, catalog, settings, today)
      prescription = Prescription.external(ExternalPrescription.includes(:items).find(record.id), catalog: catalog, settings: settings)
      Json.prescription_view(prescription, patient: patient, summary: Dispensed.summary(prescription), settings: settings, today: today, catalog: catalog)
    end
  end
end
