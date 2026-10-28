# Devolvidos da unidade solicitante (contrato §5, §13 G6; plano do api, Desvio
# 13):
#   GET /regulation/returned?unit_id=
# `health_professional` com vínculo ativo na unidade e CBO que pede regulação
# (225*, 2235*, 2232*; senão 403 missing_role). Os itens vêm com `events` (o
# motivo da devolução está no evento `returned`) e a leitura grava UMA trilha
# de lista (só os ids dos pedidos). O único parâmetro da URL é a unidade.
module CareRegulation
  class ReturnedController < BaseController
    before_action { forbid unless Current.user.has_role?("health_professional") }

    def index
      return unless query_only!("unit_id")

      unit_id = params[:unit_id]
      return render(json: { error: "invalid_request", path: "unit_id" }, status: :unprocessable_entity) unless uuid?(unit_id)
      return forbid unless requester_in?(unit_id)

      rows = RegulationRequest.where(status: "returned", requester_unit_id: unit_id).order(:requested_at, :id)
                              .preload(Queue::PRELOAD, events: { by_user: :professional }).to_a
      Trail.listed!(user: Current.user, regulation_request_ids: rows.map(&:id)) if rows.any?
      today = Time.zone.today
      render json: { requests: rows.map { |r| Json.request(r, events: true, today: today) } }
    end

    private

    def requester_in?(unit_id)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: Current.user.id }, health_unit_id: unit_id)
                      .pluck(:cbo_code).any? { |cbo| Requesters.kind(cbo) }
    end
  end
end
