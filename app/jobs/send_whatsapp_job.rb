# Envia mensagem fora-de-banda (ADR-0005/0007), pela cidade do job. O canal
# (CityChannel) é lido do catálogo de PLATAFORMA; a mensagem e o dedup ficam
# no banco da cidade.
#
# message: é o hash serializado de Messaging::Reply (via #to_h).
# Dedup contra crash-retry do worker: INSERT em outbound_messages com
# idempotency_key UNIQUE ANTES do HTTP. RecordNotUnique → skip HTTP
# (já foi entregue numa execução anterior; idempotency_key estável para
# mesmo (to, message, dedup_key) dentro da cidade). Caller pode passar dedup_key
# explícito para distinguir reenvios deliberados.
class SendWhatsappJob < ApplicationJob
  include CityScopedJob

  # I1 (hardening review): ActiveJob::LogSubscriber logs "with arguments: ..."
  # at info level for every job with log_arguments? true (the default),
  # without going through filter_parameters. This job's arguments are the
  # citizen's phone number (`to:`) and the message body (`message:`). Turned
  # off so this job never prints phone/message text to log/STDOUT (worker
  # console).
  self.log_arguments = false

  RESUME_TEMPLATE = Messaging::Reply.template(name: "rota_saude_resume").freeze

  def perform(to:, message:, city_slug:, dedup_key: nil)
    with_city(city_slug) do
      reply = Messaging::Reply.from_h(message)
      key = idempotency_key(to: to, message: message, dedup_key: dedup_key)

      outbound = nil
      begin
        outbound = OutboundMessage.create!(
          to: to,
          template: message,
          idempotency_key: key,
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

      channel = CityChannel.active.find_by!(city: Current.city)

      client = Whatsapp::Outbound.new(channel)

      sent =
        if reply.kind != :template && !Whatsapp::SessionWindow.open?(phone: to)
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

  # outbound_messages é do banco da cidade: a unicidade da chave já é por cidade.
  def idempotency_key(to:, message:, dedup_key:)
    digest_input = dedup_key.presence || [to, message.to_json].join("|")
    Digest::SHA256.hexdigest(digest_input)
  end
end
