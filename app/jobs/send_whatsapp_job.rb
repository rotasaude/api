# Envia mensagem fora-de-banda (ADR-0014/0021). Escopo manual sobre
# municipality_channels (RLS-exempt).
#
# Dedup contra crash-retry do worker: INSERT em outbound_messages com
# idempotency_key UNIQUE ANTES do HTTP. RecordNotUnique → skip HTTP
# (já foi entregue numa execução anterior; idempotency_key estável para
# mesmo (to, body, muni, dedup_key)). Caller pode passar dedup_key
# explícito para distinguir reenvios deliberados.
class SendWhatsappJob < ApplicationJob
  include TenantScopedJob

  def perform(to:, body:, municipality_id:, dedup_key: nil)
    with_tenant(municipality_id) do
      key = idempotency_key(to: to, body: body, municipality_id: municipality_id, dedup_key: dedup_key)

      outbound = nil
      begin
        outbound = OutboundMessage.create!(
          to: to,
          template: { body: body },
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

      result = Whatsapp::Outbound.new(channel).deliver_text(to: to, body: body)
      outbound.update!(status: result.status, response: result.body)
    end
  end

  private

  def idempotency_key(to:, body:, municipality_id:, dedup_key:)
    digest_input = dedup_key.presence || [to, body, municipality_id].join("|")
    Digest::SHA256.hexdigest(digest_input)
  end
end
