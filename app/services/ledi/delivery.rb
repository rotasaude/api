# Envio de um lote já reivindicado (sending) ao PEC da cidade (spec §6.4).
# 2xx → accepted; 400 → rejected; 5xx/timeout → nova tentativa com espera;
# sessão expirada → novo login uma vez; segunda recusa (ou login recusado) →
# credencial unauthorized, o resto do lote volta a pending sem contar
# tentativa e a cidade fica pausada (usable? falso) até a credencial voltar a ok.
# A credencial e o cookie nunca saem daqui: nem log, nem evento, nem last_error.
#
# PROVISÓRIO (rotasaude/api#41): duplicidade após aceite e reenvio com o mesmo
# uuid dependem do que Ledi::Outcome/Observations observaram no PEC real.
module Ledi
  class Delivery
    PAUSE_MESSAGE = "O PEC recusou a credencial durante o envio; o envio está pausado.".freeze

    def initialize(city)
      @city = city
      @credential = IntegrationCredential.find_by!(kind: "ledi")
      @client = Ledi::PecClient.new(base_url: city.pec_url, username: @credential.username,
                                    password: @credential.password)
      @cache_key = [ city.id, @credential.set_at.to_f ]
    end

    def run(entries)
      entries.each_with_index do |entry, index|
        next if deliver(entry) != :paused

        LediOutboxEntry.release!(entries[index..].map(&:id))
        return :paused
      end
      :done
    end

    private

    def deliver(entry)
      reply = post(entry)
      return pause! if reply == :unauthorized

      case Ledi::Outcome.classify(reply.status, reply.body)
      when :accepted then entry.accept!
      when :rejected then reject(entry, reply)
      else retry_later(entry, "HTTP #{reply.status}")
      end
    rescue Ledi::PecClient::Unreachable
      retry_later(entry, "PEC inacessível")
    rescue Ledi::PecClient::Failed => e
      retry_later(entry, "login no PEC respondeu #{e.status}")
    end

    def post(entry, relogged: false)
      reply = @client.deliver(cookie: cookie, filename: "#{entry.uuid}.esus", bytes: entry.bytes)
      return reply unless Ledi::Outcome.classify(reply.status, reply.body) == :unauthorized

      Ledi::SessionCache.forget(@cache_key)
      relogged ? :unauthorized : post(entry, relogged: true)
    rescue Ledi::PecClient::Unauthorized
      Ledi::SessionCache.forget(@cache_key)
      :unauthorized
    end

    def cookie
      Ledi::SessionCache.fetch(@cache_key) { @client.login.cookie }
    end

    def reject(entry, reply)
      message = Ledi::ErrorText.sanitize(Ledi::Outcome.message(reply.body))
      entry.reject!(message.presence || "HTTP #{reply.status}")
    end

    def retry_later(entry, error)
      entry.retry_later!(error: error, wait: Ledi::Backoff.wait(entry.attempts + 1),
                         give_up_after: Ledi::Backoff::GIVE_UP_AFTER)
    end

    def pause!
      @credential.update!(last_check_status: "unauthorized", last_check_at: Time.current,
                          last_check_message: PAUSE_MESSAGE)
      :paused
    end
  end
end
