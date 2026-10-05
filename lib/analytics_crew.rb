require "zlib"
require_relative "signature_crew"
require_relative "campaign_history"
require_relative "analytics_history"

# Semente de dev do módulo 14 (spec 2026-09-30 §11). Dev é fictício, mas imita
# o real: bairros da semente de território, unidades do ProfessionalCrew, CPF
# com dígito válido, respostas que seguem os ramos do protocolo, tier pelos
# pesos, desfecho, pedido e horário encadeados. Seis meses para trás, com mais
# procura em dia útil e na estação das arboviroses (março a maio).
#
# O protocolo com perguntas marcadas passa pelo ciclo assinado de verdade
# (desvio 10 do plano): SaveDraft → SubmitForReview → 2 assinaturas → Publish
# → 2 assinaturas → Activate. O histórico no passado é gravado pelo
# AnalyticsHistory (os comandos só aceitam "agora"); ao fim, Analytics::Rebuild
# consolida o período. Idempotente; nada termina no dia corrente.
class AnalyticsCrew
  SECRET_ENV = "DEV_ANALYST_OTP_SECRET"
  DEFAULT_SECRET = "MFXGC3DJON2GKZLOMFXGC3DJON2GKZLO"
  DAYS = 182
  CITIZENS = 240
  PHONE_PREFIX = "95555"
  PROTOCOL_NAME = "triagem-arbovirose"
  SYMPTOMS = [ "Dor atrás dos olhos", "Manchas vermelhas na pele", "Dor nas articulações", "Nenhum destes" ].freeze
  PROTOCOL = {
    "name" => PROTOCOL_NAME, "version" => 1, "start_step_id" => "febre",
    "steps" => [
      { "id" => "febre", "prompt" => "Teve febre nos últimos 7 dias?", "answer_type" => "boolean", "analytic" => true,
        "branches" => { "true" => "sintoma", "false" => "sintoma" }, "weights" => { "true" => 3, "false" => 0 } },
      { "id" => "sintoma", "prompt" => "Qual destes sintomas está mais forte?", "answer_type" => "enum",
        "analytic" => true, "options" => SYMPTOMS, "branches" => SYMPTOMS.to_h { |symptom| [ symptom, "gestante" ] },
        "weights" => { "Dor atrás dos olhos" => 2, "Manchas vermelhas na pele" => 3, "Dor nas articulações" => 2,
                       "Nenhum destes" => 0 } },
      # Pergunta sensível SEM marca: nunca vira agregado (ADR 0025).
      { "id" => "gestante", "prompt" => "Está gestante?", "answer_type" => "boolean",
        "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 3, "false" => 0 } }
    ],
    "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "media" => 3, "alta" => 6 },
                   "priority_map" => { "baixa" => 9, "media" => 5, "alta" => 1 } },
    "recommendations" => {
      "alta" => { "title" => "Procure atendimento hoje",
                  "body" => "Vá à unidade de saúde mais próxima ainda hoje e beba bastante líquido. Sangramento, dor forte na barriga ou tontura → 192." },
      "media" => { "title" => "Procure sua unidade de saúde",
                   "body" => "Procure sua UBS em até 24 horas. Beba bastante líquido e evite anti-inflamatórios." },
      "baixa" => { "title" => "Cuidados em casa",
                   "body" => "Repouso e hidratação. Se aparecerem febre ou manchas na pele, procure sua UBS." }
    }
  }.freeze

  # Procura por dia da semana (domingo = 0).
  WEEKDAY = [ 4, 14, 12, 11, 11, 10, 5 ].freeze
  BOOLEAN_TRUE = { "febre" => 0.55, "gestante" => 0.06, "tosse" => 0.6 }.freeze
  SYMPTOM_WEIGHTS = [ 3, 2, 3, 4 ].freeze
  # [minutos de espera base, peso]; a espera final ganha 0 a 9 min.
  WAIT_MINUTES = [ [ 6, 35 ], [ 20, 25 ], [ 40, 20 ], [ 80, 12 ], [ 140, 8 ] ].freeze
  OUTCOMES = [ [ "discharged", 60 ], [ "referred", 12 ], [ "return", 18 ], [ "left", 10 ] ].freeze
  APPOINTMENT_ENDINGS = [ [ "checked_in", 65 ], [ "no_show", 15 ], [ "expired", 10 ],
                          [ "cancelled_by_citizen", 10 ] ].freeze

  class << self
    def seed_current_city(slug:, ddd:, password:, days: DAYS)
      account = ensure_analyst(slug: slug, password: password)
      protocol = ensure_protocol!(slug)
      new_triages = seed_history!(slug: slug, ddd: ddd, days: days)
      report = Analytics::Rebuild.call(from: Time.zone.today - days)
      { account: account, protocol: { name: protocol.name, version: protocol.version, status: protocol.status },
        new_triages: new_triages, runs: report.runs.size,
        failed: report.failed&.error || (report.busy ? "outra consolidação em curso" : nil) }
    end

    private

    def ensure_analyst(slug:, password:)
      user = User.find_or_initialize_by(email_address: "analise@#{slug}.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: "analyst") { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: SECRET_ENV, default_secret: DEFAULT_SECRET)
      { email: user.email_address, role: "analyst", otpauth_uri: SignatureCrew.otpauth_uri(user) }
    end

    # Retoma de onde parou: cada passo só roda se a versão estiver no estado dele.
    def ensure_protocol!(slug)
      # Outra versão ativa (o título do módulo 15) também conta como pronto:
      # reativar a v1 faria cada db:seed alternar as versões.
      active = ProtocolDefinition.find_by(name: PROTOCOL_NAME, status: "active")
      return active if active

      record = ProtocolDefinition.find_by(name: PROTOCOL_NAME, version: 1)
      return record if record&.status == "active"

      author, first, second, publisher = %w[autor revisora1 revisora2 publisher]
                                         .map { |prefix| User.find_by!(email_address: "#{prefix}@#{slug}.demo") }
      status = -> { ProtocolDefinition.find_by!(name: PROTOCOL_NAME, version: 1).status }
      check!(Protocols::SaveDraft.call(definition: PROTOCOL.deep_dup, by: author), "rascunho") if record.nil?
      check!(Protocols::SubmitForReview.call(name: PROTOCOL_NAME, version: 1, by: author), "revisão") if status.call == "draft"
      if status.call == "in_review"
        [ first, second ].each { |reviewer| sign!(reviewer, "publication") }
        check!(Protocols::Publish.call(name: PROTOCOL_NAME, version: 1, by: publisher), "publicação")
      end
      if status.call == "published"
        [ first, second ].each { |reviewer| sign!(reviewer, "activation") }
        check!(Protocols::Activate.call(name: PROTOCOL_NAME, version: 1, by: publisher), "ativação")
      end
      ProtocolDefinition.find_by!(name: PROTOCOL_NAME, version: 1)
    end

    def sign!(reviewer, purpose)
      result = Protocols::Sign.call(name: PROTOCOL_NAME, version: 1, purpose: purpose, by: reviewer)
      check!(result, "assinatura de #{purpose}") unless result.reason == :already_signed
    end

    def check!(result, step)
      return result if result.ok?

      raise "semente do Analytics: #{step} de #{PROTOCOL_NAME} falhou — #{result.reason}: #{result.message}"
    end

    # 0 quando o histórico já existe (idempotência pelo protocolo da semente).
    def seed_history!(slug:, ddd:, days:)
      return 0 if Triage.where(protocol_name: PROTOCOL_NAME).exists?

      rng = Random.new(Zlib.crc32("analytics:#{slug}"))
      by = User.find_by!(email_address: "recepcao@#{slug}.demo")
      units = HealthUnit.where(active: true).order(:name).to_a
      raise "semente do Analytics: nenhuma unidade ativa (rode o ProfessionalCrew antes)" if units.empty?

      neighborhoods = Neighborhood.where(active: true).order(:name).to_a.sample(10, random: rng)
      raise "semente do Analytics: nenhum bairro (rode a Territory::Seed antes)" if neighborhoods.empty?

      protocols = [ ProtocolDefinition.find_by!(name: PROTOCOL_NAME, status: "active"),
                    ProtocolDefinition.find_by!(name: StartTriage::DEFAULT_PROTOCOL_NAME, status: "active") ]
      weighted_places = neighborhoods.each_with_index.map { |place, index| [ place, index < 3 ? 4 : 1 ] }
      citizens = Array.new(CITIZENS) do |index|
        neighborhood = rng.rand < 0.1 ? nil : weighted(rng, weighted_places)
        AnalyticsHistory.citizen!(cpf: CampaignHistory.cpf_for("#{slug}:analytics:#{index}"),
                                  phone: format("+55%s#{PHONE_PREFIX}%04d", ddd, index + 1), neighborhood: neighborhood)
      end

      count = 0
      ApplicationRecord.transaction do
        days.downto(1) do |ago|
          date = Time.zone.today - ago
          daily_count(date, rng).times do
            one_triage!(date, rng: rng, citizens: citizens, protocols: protocols, units: units, by: by)
            count += 1
          end
        end
      end
      count
    end

    def daily_count(date, rng)
      season = if date.month.between?(3, 5) then 1.5
               elsif date.month == 6 then 1.2
               else 0.9
               end
      (WEEKDAY[date.wday] * season * (0.8 + 0.4 * rng.rand)).round
    end

    def one_triage!(date, rng:, citizens:, protocols:, units:, by:)
      citizen = citizens[rng.rand(citizens.size)]
      protocol = rng.rand < 0.6 ? protocols.first : protocols.last
      at = Time.zone.local(date.year, date.month, date.day, 7 + rng.rand(13), rng.rand(60))
      answers = walk(protocol.definition, rng)
      roll = rng.rand
      status, revoked = if roll < 0.84 then [ "completed", false ]
                        elsif roll < 0.91 then [ "aborted_by_timeout", false ]
                        elsif roll < 0.97 then [ "aborted_by_cancellation", false ]
                        elsif roll < 0.99 then [ "completed", true ]
                        else [ "aborted_by_revocation", false ]
                        end
      tier = tier_for(protocol.definition, answers)
      given = status == "completed" ? answers : answers.first(rng.rand(answers.size)).to_h
      triage = AnalyticsHistory.triage!(citizen: citizen, protocol: protocol, created_at: at, status: status,
                                        revoked: revoked, tier: tier, answers: given,
                                        priority: protocol.definition.dig("scoring", "priority_map", tier) || 5)
      attend!(triage, rng: rng, units: units, by: by) if status == "completed" && !revoked && rng.rand < 0.7
    end

    def attend!(triage, rng:, units:, by:)
      unit = weighted(rng, units.each_with_index.map { |place, index| [ place, index.zero? ? 3 : 2 ] })
      checked_in_at = triage.completed_at + (20 + rng.rand(240)).minutes
      wait = weighted(rng, WAIT_MINUTES) + rng.rand(10)
      return if checked_in_at + (wait + 30).minutes >= Time.zone.now.beginning_of_day # nada termina hoje

      outcome = weighted(rng, OUTCOMES)
      other = units.find { |place| place != unit } || unit
      attendance = AnalyticsHistory.attendance!(citizen: triage.conversation.citizen, triage: triage, unit: unit, by: by,
                                                checked_in_at: checked_in_at, wait_minutes: wait, outcome: outcome,
                                                referral_unit: outcome == "referred" ? other : nil)
      follow_up!(attendance, rng: rng, by: by, other: other) if %w[return referred].include?(outcome)
    end

    # Pedido do desfecho e, quando o horário já passou, o fim dele: comparecimento
    # fecha o pedido (e gera o atendimento do retorno); cancelamento fecha; falta
    # e expiração reabrem, e parte dos reabertos é dispensada três dias depois.
    def follow_up!(attendance, rng:, by:, other:)
      kind = attendance.outcome == "return" ? "return" : "referral"
      scheduled_at = (attendance.closed_at + (5 + rng.rand(15)).days).change(hour: 8 + rng.rand(9), min: 0)
      today_start = Time.zone.now.beginning_of_day
      if scheduled_at + 1.day >= today_start
        AnalyticsHistory.request!(origin: attendance, kind: kind, target: other, by: by)
        return
      end

      ending = weighted(rng, APPOINTMENT_ENDINGS)
      ended_at = AnalyticsHistory.ended_at(ending, scheduled_at)
      closed_reason = { "checked_in" => "fulfilled", "cancelled_by_citizen" => "citizen_cancelled" }[ending]
      closed_at = closed_reason && ended_at
      if closed_reason.nil? && rng.rand < 0.4 && ended_at + 3.days < today_start
        closed_reason = "dismissed"
        closed_at = ended_at + 3.days
      end
      request = AnalyticsHistory.request!(origin: attendance, kind: kind, target: other, by: by,
                                          status: closed_reason ? "closed" : "open", closed_reason: closed_reason,
                                          closed_at: closed_at,
                                          reopened_reason: %w[no_show expired].include?(ending) ? ending : nil)
      appointment = AnalyticsHistory.appointment!(request: request, status: ending, scheduled_at: scheduled_at, by: by)
      return unless ending == "checked_in"

      AnalyticsHistory.attendance!(citizen: request.citizen, appointment: appointment, unit: request.target_unit, by: by,
                                   checked_in_at: appointment.ended_at, wait_minutes: weighted(rng, WAIT_MINUTES))
    end

    # Percorre o protocolo como o cidadão: resposta sorteada, próximo passo pelo ramo.
    def walk(definition, rng)
      steps = definition.fetch("steps").index_by { |step| step["id"] }
      answers = {}
      id = definition["start_step_id"]
      while id && (step = steps[id]) && !answers.key?(id)
        answer = if step["answer_type"] == "enum"
                   weighted(rng, step["options"].each_with_index.map { |option, i| [ option, SYMPTOM_WEIGHTS[i] || 1 ] })
                 else
                   rng.rand < BOOLEAN_TRUE.fetch(id, 0.5) ? "true" : "false"
                 end
        answers[id] = answer
        id = step.fetch("branches", {})[answer]
      end
      answers
    end

    # Scoring weighted: a maior faixa cujo mínimo a soma dos pesos alcança.
    def tier_for(definition, answers)
      score = definition.fetch("steps").sum do |step|
        answers.key?(step["id"]) ? step.fetch("weights", {}).fetch(answers[step["id"]], 0).to_i : 0
      end
      definition.dig("scoring", "thresholds").to_h.select { |_tier, min| score >= min }.max_by { |_tier, min| min }&.first
    end

    def weighted(rng, pairs)
      mark = rng.rand * pairs.sum(&:last)
      pairs.each { |value, weight| return value if (mark -= weight).negative? }
      pairs.last.first
    end
  end
end
