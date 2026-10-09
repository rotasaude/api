# app/commands/signatures/complete_oauth.rb
# Volta do PSC (ADR 0032; contrato §4, §13). O state é consumido na transação
# própria do OauthStates.consume, ANTES de qualquer outra coisa e fora de
# transação externa: o consumed_at fica gravado mesmo que o passo seguinte
# falhe, e o mesmo código nunca é trocado duas vezes. `{ state, error }` =
# recusa no celular (403 authorization_denied, consumindo o state). Depois,
# troca o código (PKCE) e segue estritamente pelo propósito e pelo PSC da
# linha. Toda falha depois de achar a linha leva o return_to dela.
module Signatures
  module CompleteOauth
    MAX_CODE = 2048

    module_function

    def call(user:, state:, code:, error: nil, now: Time.current)
      consumed = OauthStates.consume(state, user: user, now: now)
      return consumed if consumed.failure?

      row = consumed.payload[:state]
      outcome = proceed(row, user: user, code: code, error: error, now: now)
      return with_return_to(outcome, row) if outcome.failure?

      Result.ok(purpose: row.purpose, record: outcome.payload.fetch(:record), return_to: row.return_to)
    end

    def proceed(row, user:, code:, error:, now:)
      return Result.fail(:authorization_denied) if error.present?
      return Result.fail(:invalid_state) unless code.is_a?(String) && code.present? && code.size <= MAX_CODE

      client = Psc::Client.for(row.provider)
      token = client.exchange(code: code, verifier: row.code_verifier, redirect_uri: Providers.redirect_uri(Current.city))
      dispatch(row, user: user, client: client, token: token, now: now)
    rescue Psc::Unavailable
      Result.fail(:provider_unavailable)
    rescue Psc::Unauthorized
      Result.fail(:provider_unavailable) # a credencial da plataforma foi recusada: não é culpa do profissional
    rescue Psc::Rejected
      Result.fail(:authorization_expired) # código vencido ou já trocado no PSC
    end

    def dispatch(row, user:, client:, token:, now:)
      case row.purpose
      when "link"
        accepted = AcceptCertificate.call(user: user, provider: row.provider, entries: client.certificates(token.access_token), now: now)
        accepted.ok? ? Result.ok(record: accepted.payload[:certificate]) : accepted
      when "session"
        OpenSession.call(user: user, provider: row.provider, client: client, token: token, now: now)
      else
        Result.fail(:invalid_state)
      end
    end

    def with_return_to(result, row)
      Result.fail(result.reason, message: result.message, details: result.details.merge(return_to: row.return_to))
    end
    private_class_method :proceed, :dispatch, :with_return_to
  end
end
