# Denúncia anônima sem login (ADR 0051; contrato §4; §16 Q13, Q21, Q47;
# preflight F-3, F-4). O teto diário da cidade (`anonymous_daily_cap`, por dia
# local) é serializado pela trava da linha de ombudsman_settings (FOR UPDATE):
# dois envios na borda do teto contam um depois do outro, e nunca passam dele.
#
# - abaixo do teto: Ombudsman::Register com `anonymous_web: true` (`report` +
#   `anonymous`, canal web, sem pessoa e sem anexo) — o mesmo caminho de
#   protocolo e evento do canal do cidadão;
# - no teto: daily_cap_reached, com a transação COMMITADA — a marca do dia
#   (`ombudsman_daily_runs`, kind anonymous_cap, única por dia) fica, e só o
#   primeiro bloqueio do dia (o que inseriu a marca) publica
#   `ombudsman.anonymous_cap_reached` com payload {} (Q21).
#
# A linha de configuração é garantida ANTES da trava (Q13/Q47): o banco vindo
# do dump nasce sem ela. A hora efetiva (janela da contagem, `run_on` e
# `created_at` da marca, received_at) é lida DEPOIS da trava quando `now` não
# vem injetado: o envio que chega às 23:59:59 e pega a trava depois da
# meia-noite é do dia novo, como o occurred_at do evento que ele publica.
# Nada do texto em erro, log ou evento.
module Ombudsman
  module RegisterAnonymous
    CAP_KIND = "anonymous_cap".freeze

    module_function

    # -> Result.ok(manifestation:) | fail(:daily_cap_reached)
    #  | fail(:invalid_request, details: { path:, problems: })
    def call(body:, health_unit_id:, now: nil)
      Settings.ensure_defaults!(now: now || Time.current)
      ApplicationRecord.transaction do
        settings = OmbudsmanSetting.lock.find(1)
        now ||= Time.current
        today = now.in_time_zone.to_date
        received = OmbudsmanManifestation.where(channel: "web", identification_mode: "anonymous",
                                                received_at: now.in_time_zone.all_day).count
        next cap_reached!(today, now) if received >= settings.anonymous_daily_cap

        Register.call(attrs: { "kind" => "report", "identification_mode" => "anonymous", "body" => body,
                               "health_unit_id" => health_unit_id },
                      channel: "web", anonymous_web: true, now: now)
      end
    end

    def cap_reached!(today, now)
      marked = OmbudsmanDailyRun.insert_all([ { run_on: today, kind: CAP_KIND, created_at: now } ],
                                            unique_by: %i[run_on kind])
      DomainEvents.publish("ombudsman.anonymous_cap_reached") if marked.rows.any?
      Result.fail(:daily_cap_reached)
    end

    private_class_method :cap_reached!
  end
end
