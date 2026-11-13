# Aparelhos de campo da cidade, para o municipal_admin (módulo 24b, ADR 0052;
# contrato §9.1; Q7, Q21):
#   GET  /field_devices/admin?user_id=     todos (ou os de um usuário), com user: { id, name } e status
#   POST /field_devices/admin/:id/revoke   step-up; 409 device_already_revoked
# Quem não é municipal_admin → 403 missing_role. Não depende do interruptor.
module FieldDevices
  class AdminController < ApplicationController
    include Authentication
    include MfaStepUp

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    before_action :require_admin!
    before_action :require_step_up!, only: :revoke

    def index
      return render_refusal("invalid_request", :unprocessable_entity) unless (request.query_parameters.keys - %w[user_id]).empty?
      return render_refusal("invalid_request", :unprocessable_entity, path: "user_id") unless user_filter_valid?

      scope = FieldDevice.includes(:user, :professional).order(created_at: :desc, id: :desc)
      scope = scope.where(user_id: params[:user_id]) if params[:user_id]
      render json: { items: FieldSync::Json.devices(scope.to_a, with_user: true) }
    end

    def revoke
      device = FieldDevice.includes(:professional).find_by(id: params[:id])
      return render_refusal("not_found", :not_found) unless device

      result = FieldDevices::Revoke.call(device, by: Current.user, reason: "admin")
      return render_refusal(result.reason, :conflict) if result.failure?

      render json: { device: FieldSync::Json.devices([ device ], with_user: true).first }
    end

    private

    def require_admin!
      return if Current.user.has_role?("municipal_admin")

      render_refusal("missing_role", :forbidden)
    end

    def user_filter_valid? = params[:user_id].nil? || (params[:user_id].is_a?(String) && params[:user_id].match?(UUID))

    def render_refusal(error, status, path: nil)
      payload = { error: error.to_s }
      payload[:path] = path if path
      render json: payload, status: status
    end
  end
end
