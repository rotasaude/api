# GET /ombudsman/responder_candidates (ADR 0051; contrato §16 Q7): os usuários
# da cidade que podem virar respondente — papel `ombudsman_responder` ativo e
# conta não desativada, o mesmo critério do POST /ombudsman/responders. Só o ouvidor.
module Ombudsman
  class ResponderCandidatesController < BaseController
    before_action :require_ombudsman_role!
    before_action :query_only!

    def index
      users = User.where(deactivated_at: nil, id: Membership.active.where(role: "ombudsman_responder").select(:user_id))
                  .includes(:professional)
      items = users.map { |user| { id: user.id, name: Screenings::Json.staff_name(user), email: user.email_address } }
      render json: { items: items.sort_by { |item| [ item[:name].to_s.downcase, item[:id] ] } }
    end
  end
end
