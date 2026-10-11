# Painel do SNCR (contrato §6): municipal_admin, só leitura.
module Sncr
  class AdminController < BaseController
    skip_before_action :require_professional
    before_action :require_manager

    def overview
      render json: AdminOverview.call(simulated: Mock.on?(Current.city))
    end

    private

    def require_manager
      forbid("missing_role") unless CitizenVerificationPolicy.new(Current.user, nil).manage?
    end
  end
end
