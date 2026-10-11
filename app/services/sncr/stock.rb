# app/services/sncr/stock.rb
# Estoque de números SNCR por prescritor (ADR 0034; spec §4; Desvios 4–6). O
# lote grava o que o SNCR deu (só os números novos: o SNCR já entregou
# repetidos); a emissão tira o menor número livre do modo corrente com
# FOR UPDATE SKIP LOCKED NA TRANSAÇÃO DELA (falha → rollback devolve); usado
# só com documento; cancelamento e volta ao papel anulam (voided, sem volta).
# Nenhum número SNCR em log ou evento.
module Sncr
  module Stock
    MONTHLY_LIMIT = 3
    LOW_THRESHOLD = 50
    Received = Data.define(:batch, :received)

    module_function

    def month(now) = now.in_time_zone.to_date.beginning_of_month

    # Pedidos do mês no modo de quem pergunta (D17): em staging, simulado e
    # real contam cotas separadas (o SNCR real impõe a dele).
    def requests_this_month(user:, kind:, simulated:, now: Time.current)
      SncrNumberBatch.where(user_id: user.id, kind: kind, simulated: simulated, month: month(now)).count
    end

    def summary(user:, simulated:, now: Time.current)
      counts = SncrNumber.where(user_id: user.id, simulated: simulated).group(:kind, :status).count
      SncrNumber::KINDS.to_h do |kind|
        [ kind, { free: counts.fetch([ kind, "free" ], 0), used: counts.fetch([ kind, "used" ], 0),
                  voided: counts.fetch([ kind, "voided" ], 0), requests_this_month: requests_this_month(user: user, kind: kind, simulated: simulated, now: now) } ]
      end
    end

    def record_batch!(user:, kind:, block:, simulated:, now: Time.current)
      numbers = Numbers.expand(block.first, block.last, block.quantity)
      raise ArgumentError, "bloco inválido" unless numbers && SncrNumber::KINDS.include?(kind)

      ApplicationRecord.transaction(requires_new: true) do
        lock_key = ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "sncr:#{user.id}:#{kind}" ])
        ApplicationRecord.connection.execute(lock_key)
        current = month(now)
        batch = quietly { SncrNumberBatch.create!(user: user, kind: kind, first_number: block.first, last_number: block.last,
                                        quantity: block.quantity, month: current,
                                        month_request: requests_this_month(user: user, kind: kind, simulated: simulated, now: now) + 1,
                                        simulated: simulated, requested_at: now, created_at: now) }
        rows = numbers.map do |number|
          { kind: kind, number: number, batch_id: batch.id, user_id: user.id, simulated: simulated, status: "free", created_at: now }
        end
        inserted = quietly do
          SncrNumber.insert_all(rows, unique_by: :idx_sncr_numbers_kind_number_simulated, returning: %w[id], record_timestamps: false).length
        end
        repeated = numbers.size - inserted
        Rails.logger.warn("[sncr] lote com #{repeated} número(s) já existente(s)") if repeated.positive?
        DomainEvents.publish("sncr.numbers_requested", user_id: user.id, kind: kind, count: inserted, simulated: simulated)
        Received.new(batch: batch, received: inserted)
      end
    end

    # O SQL de debug carrega os binds: o número SNCR não pode ir ao log.
    def quietly(&) = ActiveRecord::Base.logger ? ActiveRecord::Base.logger.silence(&) : yield

    def take!(user:, kind:, simulated:, env: Rails.env)
      return nil if simulated && Platform::Features.find(Mock::KEY, env: env).nil? # sem o interruptor sncr_mock no ambiente (produção), simulado nunca sai

      SncrNumber.available.where(user_id: user.id, kind: kind, simulated: simulated)
                .order(:number).lock("FOR UPDATE SKIP LOCKED").first
    end

    def use!(number, document:, now: Time.current)
      number.update!(status: "used", document_id: document.id, used_at: now)
      DomainEvents.publish("sncr.number_used", document_id: document.id, kind: number.kind)
      number
    end

    def void!(document:, now: Time.current)
      number = SncrNumber.lock.find_by(document_id: document.id, status: "used")
      return nil unless number

      number.update!(status: "voided", voided_at: now)
      DomainEvents.publish("sncr.number_voided", document_id: document.id, kind: number.kind)
      number
    end
  end
end
