# Dispensação e histórico do paciente (contrato §7, H2, H6, H8, H12; plano do
# api, Task 11).
#
# POST /pharmacy/dispensations — `{ location_id, prescription: { kind, id },
# items: [ { prescription_item_id, catalog_item_id?, lot_id, quantity,
# complete? } ], retention?: { notification_number? } }`, só no corpo JSON
# (chave na query → 422). `pharmacist` ou `pharmacy_assistant` do local `unit`
# ativo; senão 403 missing_role sozinho. O papel gravado é `pharmacist` quando o
# usuário tem os dois no local. Receita inexistente → 404
# prescription_not_found. 201 com o <dispensation>, sem envelope. Todo 422 traz
# `problems` com todas as recusas; 403 de papel do item (controlado, texto
# livre) vem sozinho. Sem step-up. A receita e o catálogo da plataforma são
# lidos AQUI, fora da transação. Sem trilha nova: a busca da receita já deixou.
#
# GET /pharmacy/dispensations?patient_id=&before=&limit= — o histórico de
# retiradas do paciente (todos os locais), mais novas primeiro (dispensed_at,
# id), com `next_before`. Leitura NOMINAL: trilha clinical_record.viewed
# (access "pharmacy") da pessoa quando mostra alguma dispensação. Quem
# dispensa em algum local `unit` ativo; senão 403. 30 por minuto por usuário.
module Pharmacy
  class DispensationsController < BaseController
    PRELOAD = Json::DISPENSATION_PRELOAD

    rate_limit to: 30, within: 1.minute, only: :index, name: "pharmacy_dispensation_history", store: RateLimitStore,
               by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def create
      location = body_location_or_refuse
      return unless location
      return forbid unless dispenser_at?(location)
      return unless query_only!

      reference = body_param("prescription")
      return render_refusal("prescription") unless reference.is_a?(Hash)
      return render_refusal("prescription.kind") unless Catalog::PRESCRIPTION_KINDS.include?(reference["kind"])

      settings = Settings.current
      prescription = Prescription.find(kind: reference["kind"], id: reference["id"], settings: settings)
      return render_error(:prescription_not_found, :not_found) unless prescription

      items = body_param("items")
      catalog = catalog_for(prescription, items)
      result = Dispense.call(location: location, prescription: prescription, items: items, retention: body_param("retention"), by: Current.user,
                             role: role_at(location), catalog: catalog, settings: settings)
      return render_failure(result) if result.failure?

      saved = Dispensation.includes(*PRELOAD).find(result.payload.fetch(:dispensation).id)
      render json: Json.dispensation(saved, catalog: catalog, patient: Patient.find(saved.patient_id)), status: :created
    end

    def index
      return forbid unless dispenser_anywhere?
      return unless query_only!(:patient_id, :before, :limit)

      raw = params[:patient_id]
      patient = uuid?(raw) ? Patient.find_by(id: raw) : nil
      return render_refusal("patient_id") unless patient

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      scope = Dispensation.where(patient_id: patient.id)
      scope = scope.where("(dispensations.dispensed_at, dispensations.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.includes(*PRELOAD).order(dispensed_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      Trail.person_viewed!(user: Current.user, patient_id: patient.id) if page.any?

      lines = page.flat_map(&:items)
      catalog = Json.catalog_for(lines.map(&:catalog_item_id))
      returned = Dispensed.returned_totals(lines.map(&:id))
      render json: { dispensations: page.map { |row| Json.dispensation(row, catalog: catalog, patient: patient, returned: returned) },
                     next_before: rows.size > limit ? Cursor.encode([ page.last.dispensed_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    private

    # O papel que vale na gravação: o farmacêutico, se o usuário também é um.
    def role_at(location)
      Access.allowed?(user: Current.user, location: location, roles: %w[pharmacist]) ? "pharmacist" : "pharmacy_assistant"
    end

    # Itens do catálogo da receita e os escolhidos no corpo (só ids uuid, só as
    # primeiras linhas: o resto o comando recusa por tamanho), numa consulta.
    def catalog_for(prescription, items)
      chosen = Array(items).first(Catalog::MAX_DISPENSE_ITEMS).filter_map { |row| row["catalog_item_id"] if row.is_a?(Hash) && uuid?(row["catalog_item_id"]) }
      Json.catalog_for(prescription.items.filter_map(&:catalog_item_id) + chosen)
    end
  end
end
