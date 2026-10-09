# app/jobs/signatures/sign_job.rb
# Assina um pedido na fila da cidade (ADR 0032; spec §5). Falha passageira:
# até 3 tentativas com espera crescente (30 s, 2 min); depois o pedido fica
# pending com o motivo, à espera do lote ou da volta ao papel. Nunca levanta
# por PSC/signer (a transação do CityScopedJob commita o motivo). Nunca
# atribui Current.city (CityScopedJob#with_city).
module Signatures
  class SignJob < ApplicationJob
    include CityScopedJob

    queue_as :default

    BACKOFF = [ 30.seconds, 2.minutes ].freeze

    def perform(city_slug:, request_id:)
      with_city(city_slug) do
        next unless SignPending.call(request_id: request_id) == :retry

        attempts = SignatureRequest.where(id: request_id).pick(:attempts).to_i
        self.class.set(wait: BACKOFF.fetch(attempts - 1, BACKOFF.last)).perform_later(city_slug: city_slug, request_id: request_id)
      end
    end
  end
end
