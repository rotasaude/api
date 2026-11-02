# Envio de um lote já reivindicado (`sending`) à RNDS (ADR 0047, Desvios 12 a
# 16; §15 V7, V23). Por entrada:
#
#   1. cancelamento: o rnds_id do original (aceito sem ele — 201 sem Location —
#      não há Bundle substituto possível: `failed` com `original_without_rnds_id`);
#   2. validação NT 115 (Rnds::Validation): bloqueio → `blocked` (revalida em
#      1 h); CADSUS ou banco da cidade fora do ar → nova tentativa com espera;
#   3. Bundle RIA-R → payload cifrado + tentativa marcada → POST (fora de
#      transação): 201 → `accepted` (payload anulado); 400/422 → `rejected` com
#      o diagnóstico limpo; 5xx/timeout → espera crescente, `failed` só 15 dias
#      depois da primeira tentativa; 401/403 → credencial `unauthorized`, esta
#      entrada e o resto do lote voltam a `pending` sem contar tentativa, e o
#      envio da cidade pausa (`rnds_immunization` inutilizável) até a
#      credencial voltar a ok.
#
# O alvo (simulado × real) sai do `Rnds::Mock.on?` (usable?), não do
# `Rnds::Config.for_city` (que é do teste da credencial). Erro inesperado numa
# entrada não trava o lote: só a classe vai para o relatório de erro, e a fila
# guarda só um código. CPF, CNS, vacina e o Bundle nunca saem daqui.
module Rnds
  class Delivery
    PAUSE_MESSAGE = "A RNDS recusou a credencial durante o envio; o envio está pausado.".freeze
    ORIGINAL_WITHOUT_RNDS_ID = "original_without_rnds_id".freeze

    def initialize(city)
      @city = city
      settings = Rnds::Mock.on?(city) ? Rnds::Config.simulated : Rnds::Config.real(city)
      @client = Rnds::Client.for(city, settings: settings)
      @credential = IntegrationCredential.find_by!(kind: "rnds")
      @cache = {}
    end

    # -> :done | :paused
    def run(entries)
      entries.each_with_index do |entry, index|
        next unless deliver(entry) == :paused

        RndsOutboxEntry.release!(entries[index..].map(&:id))
        return :paused
      end
      :done
    end

    private

    def deliver(entry)
      immunization = entry.immunization
      original_rnds_id = nil
      if entry.kind == "cancellation"
        original_rnds_id = RndsOutboxEntry.find_by(immunization_id: immunization.id, kind: "application")&.rnds_id
        return entry.fail!(ORIGINAL_WITHOUT_RNDS_ID) if original_rnds_id.blank?
      end

      verdict = Rnds::Validation.call(immunization: immunization, entry: entry, city: @city, cache: @cache)
      return retry_later(entry, "identity_check_unavailable") if verdict == :retry_later
      return entry.block!(verdict.last) if verdict.is_a?(Array)

      send_bundle(entry, immunization, original_rnds_id)
    rescue *Maintenance::CityConnectionErrors::CLASSES
      retry_later(entry, "city_unreachable")
    rescue StandardError => e
      Rails.error.report(RuntimeError.new("rnds delivery: #{e.class.name}"), handled: true, severity: :error)
      retry_later(entry, "internal_error")
    end

    def send_bundle(entry, immunization, original_rnds_id)
      bundle = Rnds::Bundle.build(immunization: immunization, kind: entry.kind, cnes: @credential.requester_cnes, now: Time.current,
                                  original_rnds_id: original_rnds_id)
      previous = entry.sending!(bundle)
      response = @client.post_bundle(bundle, practitioner_cns: immunization.vaccinator_user.professional&.cns)
      case response.status
      when :accepted then entry.accept!(response.rnds_id)
      when :rejected then entry.reject!(response.error)
      when :unauthorized
        entry.unsent!(previous)
        pause!
      else retry_later(entry, "rnds_unavailable")
      end
    end

    def retry_later(entry, code)
      entry.retry_later!(error: code, wait: Rnds::Backoff.wait(entry.attempts + 1), give_up_after: Rnds::Backoff::GIVE_UP_AFTER)
    end

    # Só marca a credencial usada no lote: trocada no meio (set_at novo), a
    # nova não herda a recusa da antiga.
    def pause!
      IntegrationCredential.where(id: @credential.id, set_at: @credential.set_at)
                           .update_all(last_check_status: "unauthorized", last_check_at: Time.current,
                                       last_check_message: PAUSE_MESSAGE, updated_at: Time.current)
      :paused
    end
  end
end
