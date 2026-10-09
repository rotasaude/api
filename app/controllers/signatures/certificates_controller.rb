# app/controllers/signatures/certificates_controller.rb
# Minha conta → Assinatura digital (contrato §3). Vincular e desvincular pedem
# step-up (ADR 0016).
module Signatures
  class CertificatesController < BaseController
    rate_limit to: 10, within: 1.minute, only: :discover,
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    def show
      certificate = SignerCertificate.active.find_by(user_id: Current.user.id)
      return render(json: { error: "certificate_not_linked" }, status: :not_found) unless certificate

      render json: Json.certificate(certificate)
    end

    def discover
      result = Discover.call(user: Current.user)
      return failure(result) if result.failure?

      render json: result.payload
    end

    def link
      return require_step_up! unless reauthenticated_recently?

      result = StartLink.call(user: Current.user, provider: body["provider"], return_to: body["return_to"])
      return failure(result) if result.failure?

      render json: result.payload
    end

    def destroy
      return require_step_up! unless reauthenticated_recently?

      result = Unlink.call(user: Current.user)
      return failure(result, certificate_not_linked: :not_found) if result.failure?

      head :no_content
    end
  end
end
