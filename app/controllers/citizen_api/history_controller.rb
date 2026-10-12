#   GET /citizen/history?citizen_id=&before=&limit=
#   GET /citizen/health_summary?citizen_id=
#   GET /citizen/documents/:id/pdf?citizen_id=
# Linha do tempo do cidadão (ADR 0035; contrato §4). Só pares do celular da
# sessão (senão 404). Par validado: a pessoa inteira, sem texto clínico
# livre; par declarado: triagens e agendamentos do próprio par. Toda leitura
# deixa trilha `citizen`.
module CitizenApi
  class HistoryController < BaseController
    include FeatureGate

    require_feature :patient_timeline
    rate_limit to: 30, within: 10.minutes, only: :document_pdf, name: "citizen_document_pdf",
               by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }

    def index
      citizen = own_citizen
      return unless citizen

      requested = requested_kinds
      return render_error("invalid_kinds", :unprocessable_entity) unless requested

      person = Timeline::Person.for_citizen(citizen)
      # Defesa: for_citizen hoje não devolve pessoa vazia, mas a regra "nunca trilha
      # de pessoa vazia" não deve depender disso.
      return render_error("not_found", :not_found) if person.empty?

      kinds = Timeline::Query.citizen_kinds(verified: person.verified, documents: ClinicalDocuments::Gate.usable?(Current.city)) & requested
      page = Timeline::Query.call(person: person, kinds: kinds, before: Timeline::Cursor.decode(params[:before]),
                                  limit: Timeline::Query.limit(params[:limit]))
      Timeline::Trail.viewed!(person: person, access: "citizen")
      render json: { verified: person.verified, partial: Timeline::Gate.partial?(Current.city),
                     entries: page.entries.map { |entry| Timeline::Json.citizen(entry) }, next_before: page.next_before }
    rescue Timeline::Cursor::Invalid
      render_error("invalid_cursor", :unprocessable_entity)
    end

    def health_summary
      citizen = own_citizen
      return unless citizen
      return render_error("not_verified", :forbidden) unless citizen.verification_level_verified?

      person = Timeline::Person.for_citizen(citizen)
      patient = person.patient_id && ClinicalRecord::Gate.usable?(Current.city) ? Patient.find_by(id: person.patient_id) : nil
      return render_error("not_available", :not_found) unless patient

      Timeline::Trail.viewed!(person: person, access: "citizen")
      render json: Timeline::CitizenSummary.call(patient: patient, person: person)
    end

    def document_pdf
      citizen = own_citizen
      return unless citizen
      return render_error("not_verified", :forbidden) unless citizen.verification_level_verified?

      person = Timeline::Person.for_citizen(citizen)
      document = ClinicalDocuments::Gate.usable?(Current.city) ? Timeline::CitizenDocuments.find(person: person, id: params[:id]) : nil
      bytes = document && Timeline::CitizenDocuments.pdf(document)
      return render_error("not_found", :not_found) unless bytes

      Timeline::Trail.viewed!(person: person, access: "citizen")
      response.headers["Cache-Control"] = "no-store"
      send_data bytes, type: "application/pdf", disposition: "attachment", filename: "documento-#{document.short_code}.pdf"
    end

    private

    # kinds[] ausente = todos (W3); fora da lista dos 8, ou escalar, = nil.
    def requested_kinds
      raw = params[:kinds]
      return Timeline::KINDS if raw.blank?

      raw.is_a?(Array) && raw.all? { |kind| Timeline::KINDS.include?(kind) } ? raw : nil
    end

    def own_citizen
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      render_error("not_found", :not_found) unless citizen
      citizen
    end
  end
end
