# GET/POST/PATCH /ombudsman/responders (ADR 0051; contrato §7): quem responde
# os encaminhamentos de cada setor ou unidade. Só o ouvidor.
module Ombudsman
  class RespondersController < BaseController
    before_action :require_ombudsman_role!
    before_action :query_only!

    def index
      rows = OmbudsmanResponder.includes({ user: :professional }, :department, :health_unit).order(:created_at, :id)
      render json: { items: rows.map { |row| json(row) } }
    end

    def create
      result = SaveResponder.call(responder: nil, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: json(result.payload[:responder]), status: :created
    end

    def update
      responder = uuid?(params[:id]) ? OmbudsmanResponder.find_by(id: params[:id]) : nil
      return not_found unless responder

      result = SaveResponder.call(responder: responder, attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: json(result.payload[:responder])
    end

    private

    def json(row)
      destination = row.department || row.health_unit
      { id: row.id, user: { id: row.user_id, email: row.user.email_address, name: Screenings::Json.staff_name(row.user) },
        destination: { kind: row.department ? "department" : "health_unit", id: destination.id, name: destination.name },
        active: row.active }
    end
  end
end
