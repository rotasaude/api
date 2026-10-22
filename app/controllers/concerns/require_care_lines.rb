# Interruptor care_lines nas rotas do cidadão (ADR 0040; contrato §1):
# desligado ou sem o prontuário utilizável → 403 feature_disabled.
module RequireCareLines
  extend ActiveSupport::Concern

  included do
    before_action :require_care_lines!
  end

  private

  def require_care_lines!
    return if CareLines::Gate.usable?(Current.city)

    render json: { error: "feature_disabled", feature: CareLines::Gate::KEY }, status: :forbidden
  end
end
