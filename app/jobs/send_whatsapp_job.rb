# Envia mensagem fora-de-banda (ADR-0014/0021). Escopo manual sobre
# municipality_channels (RLS-exempt).
#
# message: é o hash serializado de Messaging::Reply (via #to_h).
# Dedup contra crash-retry do worker: INSERT em outbound_messages com
# idempotency_key UNIQUE ANTES do HTTP. RecordNotUnique → skip HTTP
# (já foi entregue numa execução anterior; idempotency_key estável para
# mesmo (to, message, muni, dedup_key)). Caller pode passar dedup_key
# explícito para distinguir reenvios deliberados.
class SendWhatsappJob < ApplicationJob
  include TenantScopedJob

  # Enfileira DENTRO da transação aberta pelo caller (o with_lock do
  # ProcessInboundMessageJob), em vez de adiar para after_commit (config global
  # :always). Seguro: os args são primitivos (sem registro AR não-commitado) e o
  # Solid Queue é o mesmo Postgres, então a linha do job comita atomicamente com
  # o avanço de estado. Já é idempotente via idempotency_key. (F-02.8)
  self.enqueue_after_transaction_commit = false

  RESUME_TEMPLATE = Messaging::Reply.template(name: "rota_saude_resume").freeze

  def perform(to:, message:, municipality_id:, dedup_key: nil)
    with_tenant(municipality_id) do
      reply = Messaging::Reply.from_h(message)
      key = idempotency_key(to: to, message: message, municipality_id: municipality_id, dedup_key: dedup_key)

      outbound = nil
      begin
        outbound = OutboundMessage.create!(
          to: to,
          template: message,
          idempotency_key: key,
          municipality_id: municipality_id,
          status: 0,                                # pendente (pré-HTTP)
          context: { dedup_key: dedup_key }.compact
        )
      rescue ActiveRecord::RecordNotUnique
        Rails.logger.info("[SendWhatsappJob] skip duplicate key=#{key}")
        return
      rescue ActiveRecord::RecordInvalid => e
        # Rails uniqueness validation dispara antes do DB constraint —
        # mesmo efeito do RecordNotUnique. Distingue pelo errors hash.
        if e.record.errors.where(:idempotency_key, :taken).any?
          Rails.logger.info("[SendWhatsappJob] skip duplicate key=#{key}")
          return
        end
        raise
      end

      channel = ApplicationRecord.connected_to(role: :admin) do
        MunicipalityChannel.find_by!(municipality_id: municipality_id, active: true)
      end

      client = Whatsapp::Outbound.new(channel)

      sent =
        if reply.kind != :template && !Whatsapp::SessionWindow.open?(phone: to, municipality_id: municipality_id)
          RESUME_TEMPLATE
        else
          reply
        end

      result =
        case sent.kind
        when :template then client.deliver_template(to: to, reply: sent)
        when :text     then client.deliver_text(to: to, body: sent.body)
        else                client.deliver_interactive(to: to, reply: sent)
        end

      outbound.update!(status: result.status, response: result.body, template: sent.to_h)
    end
  end

  private

  def idempotency_key(to:, message:, municipality_id:, dedup_key:)
    digest_input = dedup_key.presence || [to, message.to_json, municipality_id].join("|")
    Digest::SHA256.hexdigest(digest_input)
  end
end
