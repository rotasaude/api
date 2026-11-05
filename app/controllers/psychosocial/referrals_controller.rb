# Encaminhamentos ao CAPS (ADR 0049; contrato §4):
#   POST /psychosocial/referrals       escrita da UBS (health_professional com
#                                      vínculo fora do CAPS, em contexto) → 201
#   GET  /psychosocial/referrals?health_unit_id&status&before
#                                      fila do CAPS lotado, sem o motivo, sem trilha
#                                      (sem os anonimizados pela exclusão LGPD)
#   GET  /psychosocial/referrals/:id   detalhe com o motivo e a trilha
#                                      (`resource: "referral"`); outro CAPS ou
#                                      anonimizado pela exclusão LGPD → 404, sem trilha
# Lista do mais novo para o mais antigo (created_at, id), em páginas de PAGE,
# com `next_before` (cursor opaco; nulo na última). Paciente e motivo só no corpo.
module Psychosocial
  class ReferralsController < BaseController
    PAGE = 100

    def create
      return unless query_only!

      result = CreateReferral.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.referral_created(result.payload.fetch(:referral)), status: :created
    end

    def index
      return unless query_only!("health_unit_id", "status", "before")

      query = request.query_parameters
      unit = staff_unit!(query["health_unit_id"])
      return unless unit

      status = query["status"]
      return render_refusal("status") if status && !Catalog::REFERRAL_STATUSES.include?(status)

      scope = PsychosocialReferral.where(health_unit_id: unit.id, anonymized_at: nil)
      scope = scope.where(status: status) if status
      if query.key?("before")
        at, id = CareRegulation::Cursor.decode_page(query["before"])
        scope = scope.where("(psychosocial_referrals.created_at, psychosocial_referrals.id) < (?, ?)", at, id)
      end
      rows = scope.includes(:patient, :from_health_unit).order(created_at: :desc, id: :desc).limit(PAGE + 1).to_a
      page = rows.first(PAGE)
      render json: { items: page.map { |referral| Json.referral_item(referral) },
                     next_before: rows.size > PAGE ? CareRegulation::Cursor.encode_page(page.last.created_at, page.last.id) : nil }
    rescue CareRegulation::Cursor::Invalid
      render_refusal("before", "invalid_cursor")
    end

    def show
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      referral = uuid?(params[:id]) ? PsychosocialReferral.find_by(id: params[:id]) : nil
      return not_found unless referral && referral.anonymized_at.nil? && Access.can_read?(Current.user, referral)

      Trail.viewed!(patient: referral.patient_id, user: Current.user, resource: "referral")
      render json: Json.referral(referral)
    end
  end
end
