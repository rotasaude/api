# /exams/admin/* (contrato §5): municipal_admin; escrita com step-up.
module Exams
  module Admin
    class BaseController < Exams::BaseController
      before_action { forbid("missing_role") unless Current.user.has_role?("municipal_admin") }
      before_action :require_step_up!, if: -> { request.post? || request.patch? || request.delete? }
    end
  end
end
