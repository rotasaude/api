# app/commands/signatures/start_batch.rb
# Começa o lote (ADR 0032; spec §5; contrato §5): os pendentes do próprio
# autor (todos ou os escolhidos), até 50, mais antigos primeiro, numa
# aprovação multi_signature. O PSC do certificado precisa continuar
# habilitado para a cidade (D6; interruptor signature_psc_mock).
module Signatures
  module StartBatch
    LIMIT = 50
    SCOPE = "multi_signature".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def call(user:, request_ids: nil, return_to: nil)
      certificate = SignerCertificate.active.find_by(user_id: user.id)
      return Result.fail(:certificate_not_linked) unless certificate
      return Result.fail(:invalid_provider) unless Providers.configured?(certificate.provider, city: Current.city)

      cpf = user.professional&.cpf
      return Result.fail(:professional_cpf_missing) if cpf.blank?

      scope = SignatureRequest.pending.where(author_user_id: user.id)
      scope = scope.where(id: Array(request_ids).grep(String).grep(UUID)) unless request_ids.nil?
      ids = scope.order(:created_at, :id).limit(LIMIT).pluck(:id)
      return Result.fail(:nothing_pending) if ids.empty?

      issued = OauthStates.issue!(user: user, purpose: "batch", provider: certificate.provider, request_ids: ids,
                                  return_to: return_to)
      url = Psc::Client.for(certificate.provider).authorize_url(state: issued.state, challenge: issued.challenge,
                                                                scope: SCOPE, login_hint: cpf,
                                                                redirect_uri: Providers.redirect_uri(Current.city))
      Result.ok(authorize_url: url, count: ids.size)
    end
  end
end
