# Step-up de MFA: ações de alto risco exigem reverificação TOTP recente
# mesmo que a sessão esteja autenticada (ADR-0022, ADR-0016 publicação).
module MfaStepUp
  extend ActiveSupport::Concern

  STEP_UP_WINDOW = 5.minutes

  def reauthenticated_recently?(via: :totp, within: STEP_UP_WINDOW)
    return false if Current.session.nil?
    return false if via == :totp && !Current.user.mfa_enrolled?
    ts = Current.session.mfa_verified_at
    ts.present? && ts > within.ago
  end

  def require_step_up!
    return if reauthenticated_recently?
    render json: { error: "mfa_required" }, status: :unauthorized
  end
end
