# Envio de um lote já reivindicado (sending) ao PEC da cidade (spec §6.4).
# 2xx → accepted; 400 → rejected; 5xx/timeout → nova tentativa com espera;
# sessão expirada → novo login uma vez; segunda recusa (ou login recusado) →
# credencial unauthorized, o resto do lote volta a pending sem contar
# tentativa e a cidade fica pausada (usable? falso) até a credencial voltar a ok.
# PEC fora do ar (ou com erro) NO LOGIN é falha da cidade (R33): só a ficha da
# vez conta tentativa, o resto volta a pending sem contar e o lote para — um
# login (um timeout) por execução, nunca um por ficha.
# A credencial e o cookie nunca saem daqui: nem log, nem evento, nem last_error.
#
# PROVISÓRIO (rotasaude/api#41): duplicidade após aceite e reenvio com o mesmo
# uuid dependem do que Ledi::Outcome/Observations observaram no PEC real.
module Ledi
  class Delivery
    PAUSE_MESSAGE = "O PEC recusou a credencial durante o envio; o envio está pausado.".freeze

    INVALID_URL_MESSAGE = "endereço do PEC inválido".freeze

    # Login sem resposta útil do PEC (inacessível ou com erro): para o lote.
    class LoginDown < StandardError; end

    def initialize(city)
      @city = city
      @credential = IntegrationCredential.find_by!(kind: "ledi")
      @client = Ledi::PecClient.new(base_url: city.pec_url, username: @credential.username,
                                    password: @credential.password)
      @cache_key = [ city.id, @credential.set_at.to_f ]
    end

    def run(entries)
      entries.each_with_index do |entry, index|
        outcome = deliver(entry)
        next unless %i[paused halted].include?(outcome)

        LediOutboxEntry.release!(entries[index..].map(&:id))
        return outcome == :paused ? :paused : :done
      end
      :done
    end

    private

    def deliver(entry)
      reply = post(entry)
      return pause! if reply == :unauthorized

      case Ledi::Outcome.classify(reply.status, reply.body)
      # PROVISÓRIO (rotasaude/api#41): se accept! levantar DEPOIS de um 2xx, o
      # rescue de StandardError (R32) agenda o reenvio de uma ficha que o PEC já
      # aceitou; o que o PEC faz com esse reenvio só se sabe com o PEC real.
      when :accepted then entry.accept!
      when :rejected then reject(entry, reply)
      else retry_later(entry, "HTTP #{reply.status}")
      end
    rescue LoginDown => e
      retry_later(entry, e.message)
      :halted
    rescue Ledi::PecClient::InvalidUrl
      # R38: endereço do PEC inválido é falha da cidade (como o login): para o lote.
      retry_later(entry, INVALID_URL_MESSAGE)
      :halted
    rescue Ledi::PecClient::Unreachable
      retry_later(entry, "PEC inacessível")
    rescue StandardError => e
      # R32: erro inesperado numa ficha não trava o lote. Só o nome da classe
      # vai para last_error, nunca a mensagem (pode carregar dado da ficha).
      Rails.error.report(e, handled: true, severity: :error)
      retry_later(entry, "erro interno (#{e.class.name})")
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
    rescue Ledi::PecClient::InvalidUrl
      raise LoginDown, INVALID_URL_MESSAGE
    rescue Ledi::PecClient::Unreachable
      raise LoginDown, "PEC inacessível"
    rescue Ledi::PecClient::Failed => e
      raise LoginDown, "login no PEC respondeu #{e.status}"
    end

    def reject(entry, reply)
      message = Ledi::ErrorText.sanitize(Ledi::Outcome.message(reply.body))
      entry.reject!(message.presence || "HTTP #{reply.status}")
    end

    def retry_later(entry, error)
      entry.retry_later!(error: error, wait: Ledi::Backoff.wait(entry.attempts + 1),
                         give_up_after: Ledi::Backoff::GIVE_UP_AFTER)
    end

    # Só marca a credencial usada no lote: se ela foi trocada no meio (set_at
    # novo), a nova não herda a recusa da antiga (R35).
    def pause!
      IntegrationCredential.where(id: @credential.id, set_at: @credential.set_at)
                           .update_all(last_check_status: "unauthorized", last_check_at: Time.current,
                                       last_check_message: PAUSE_MESSAGE, updated_at: Time.current)
      :paused
    end
  end
end
