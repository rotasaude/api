# "Reenviar" ficha recusada (spec §6.5; contratos §5.3). O uuid segue a prova
# técnica: mesmo uuid quando o PEC aceitou o mesmo uuid depois de um 400, uuid
# novo (no transporte e na ficha) quando não aceitou.
module Ledi
  module Resend
    class NotRejected < StandardError; end
    class ExportUnusable < StandardError; end
    class NotRegenerated < StandardError; end

    module_function

    def call(entry:, by:)
      return regenerate(entry, by) if entry.source_type == Ledi::ScreeningFicha::SOURCE_TYPE

      entry.with_lock do
        raise NotRejected unless entry.status == "rejected"

        # first_attempt_at nil: reenviar reinicia a janela de 24h (contrato §8).
        attrs = { status: "pending", last_error_codes: [], next_attempt_at: Time.current, first_attempt_at: nil }
        # PROVISÓRIO: a política vem de pec_observations.yml (resend_after_rejection.same_uuid
        # = accepted ainda não provado contra PEC real). Gate de go-live: rotasaude/api#41.
        if Ledi::Observations.resend_uuid_policy == :new
          uuid = "#{entry.uuid.split('-').first}-#{SecureRandom.uuid}"
          attrs.merge!(uuid: uuid, bytes: Ledi::Transport.rewrap(entry.bytes, uuid: uuid))
        end
        entry.update!(attrs)
        DomainEvents.publish("ledi.ficha_resent", outbox_id: entry.id, user_id: by.id)
      end
      Ledi::DeliverJob.perform_later
      entry
    end

    # ADR 0030 (spec §5): ficha de escuta não reaproveita o conteúdo antigo —
    # é regerada da origem (linha nova, outro uuid, replaces_outbox_id).
    def regenerate(entry, by)
      status, fresh = Ledi::ScreeningFicha.regenerate(entry, by: by)
      case status
      when :ok then fresh
      when :not_rejected then raise NotRejected
      when :export_unusable then raise ExportUnusable
      else raise NotRegenerated
      end
    end
  end
end
