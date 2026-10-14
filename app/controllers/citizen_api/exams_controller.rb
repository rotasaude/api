#   GET /citizen/exams?citizen_id=&before=&limit=
#   GET /citizen/exams/:id/pdf?citizen_id=
# "Meus exames" (ADR 0036; contrato §9 com A22/A23/A29). Só pares do celular
# da sessão (senão 404); par declarado: lista vazia e PDF 403 not_verified.
# O laudo sai só pela política (Exams::Release), aplicada aqui: qualquer
# recusa é o mesmo 404 not_found, sem trilha. Toda leitura deixa trilha citizen.
module CitizenApi
  class ExamsController < BaseController
    rate_limit to: 30, within: 10.minutes, only: :pdf, name: "citizen_exam_pdf",
               by: -> { current_citizen_session&.id || request.remote_ip }, store: RateLimitStore,
               with: -> { render_error("too_many_requests", :too_many_requests) }
    before_action :require_exam_tracking!

    def index
      citizen = own_citizen
      return unless citizen
      return render(json: { verified: false, exams: [], next_before: nil }) unless citizen.verification_level_verified?

      person = Timeline::Person.for_citizen(citizen)
      page = Exams::CitizenList.call(person: person, before: params[:before], limit: Timeline::Query.limit(params[:limit]))
      Timeline::Trail.viewed!(person: person, access: "citizen") unless person.empty?
      render json: { verified: true, exams: page[:exams], next_before: page[:next_before] }
    rescue Exams::Cursor::Invalid
      render_error("invalid_cursor", :unprocessable_entity)
    end

    def pdf
      citizen = own_citizen
      return unless citizen
      return render_error("not_verified", :forbidden) unless citizen.verification_level_verified?

      person = Timeline::Person.for_citizen(citizen)
      result = find_result(person)
      return render_error("not_found", :not_found) unless Exams::Release.available?(result)

      Exams::Trail.citizen_viewed!(person: person, result: result)
      response.headers["Cache-Control"] = "no-store"
      send_data result.pdf_file.bytes, type: "application/pdf", disposition: "attachment", filename: "exame-#{result.id[0, 8]}.pdf"
    end

    private

    def require_exam_tracking!
      return if Exams::Gate.usable?(Current.city)

      render json: { error: "feature_disabled", feature: Exams::Gate::KEY }, status: :forbidden
    end

    def own_citizen
      citizen = current_citizen_session.citizens.find_by(id: params[:citizen_id])
      render_error("not_found", :not_found) unless citizen
      citizen
    end

    # O id é de um pedido (o resultado dele) ou de um resultado externo, do
    # paciente da pessoa. Id de resultado de pedido não vale (só o do pedido).
    def find_result(person)
      id = params[:id]
      return nil unless person.patient_id && id.is_a?(String) && id.match?(Exams::BaseController::UUID)

      ExamOrder.find_by(id: id, patient_id: person.patient_id)&.result ||
        ExamResult.find_by(id: id, patient_id: person.patient_id, origin: "external")
    end
  end
end
