# Volta do login do SNCR (ADR 0034; contrato §4; Desvios 1–5). O state é
# consumido ANTES de tudo, na transação própria do 19b (uso único mesmo que o
# passo seguinte falhe). Depois, na mesma requisição e dentro dos 30 s: troca
# o session_id pelo token (Origin = host da cidade) e pede o bloco; o token é
# uma variável local e nunca é gravado. O lote é gravado só com resposta 201.
# Toda falha depois de achar o state leva o return_to dele.
module Sncr
  module CompleteRequest
    PURPOSES = { "sncr_rce" => "rce", "sncr_ret" => "ret" }.freeze
    MAX_SESSION_ID = 512

    module_function

    def call(user:, state:, session_id:, error: nil, now: Time.current)
      consumed = Signatures::OauthStates.consume(state, user: user, now: now)
      return consumed if consumed.failure?

      row = consumed.payload[:state]
      kind = PURPOSES[row.purpose]
      return with_return_to(Result.fail(:invalid_state), row) unless kind

      outcome = proceed(row, kind, user: user, session_id: session_id, error: error, now: now)
      return with_return_to(outcome, row) if outcome.failure?

      Result.ok(**outcome.payload, return_to: row.return_to)
    end

    def proceed(row, kind, user:, session_id:, error:, now:)
      return Result.fail(:authorization_denied) if error.present?
      return Result.fail(:invalid_state) unless session_id.is_a?(String) && session_id.size.between?(1, MAX_SESSION_ID)

      professional = user.professional
      return Result.fail(:cbo_not_allowed) unless StartRequest::COUNCILS.include?(professional&.council)

      client = Client.for(Current.city)
      return Result.fail(:sncr_unavailable) unless client.provider == row.provider # o sncr_mock virou no meio do caminho

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      token = client.exchange(session_id: session_id, origin: CityPublicUrl.base(Current.city))
      block = client.request_block(token: token, kind: kind, council: professional.council,
                                   registration: professional.registration_number, uf: professional.council_state)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      Rails.logger.warn("[sncr] troca e pedido levaram #{elapsed.round(1)} s") if elapsed > 20
      received = Stock.record_batch!(user: user, kind: kind, block: block, simulated: client.simulated?, now: now)
      Result.ok(kind: kind, received: received.received, batch_id: received.batch.id)
    rescue Client::Expired
      Result.fail(:authorization_expired)
    rescue Client::LimitReached
      Result.fail(:monthly_limit_reached)
    rescue Client::Exhausted
      Result.fail(:sncr_exhausted)
    rescue Client::RegistrationMismatch
      Result.fail(:registration_mismatch)
    rescue Client::Unavailable
      Result.fail(:sncr_unavailable)
    end

    def with_return_to(result, row)
      Result.fail(result.reason, message: result.message, details: result.details.merge(return_to: row.return_to))
    end
    private_class_method :proceed, :with_return_to
  end
end
