module Regulation
  # Situação MIRA de um pedido da 26a e os passos intermediários da falta
  # (módulo 26c; Valores 5 e 6; Q7). Regras puras sobre fatos já lidos: não
  # grava nada e não conhece o envio.
  module RndsStatus
    Target = Data.define(:status, :at)

    ABSENCE = "absence".freeze

    # situação da 26a => [situação MIRA, andamentos que levam a ela]
    RULES = {
      "pending" => [ "pending", %w[pending authorized external] ],
      "authorized" => [ "pending", %w[pending authorized external] ],
      "external" => [ "pending", %w[pending authorized external] ],
      "returned" => [ "returned-to-requester", %w[returned] ],
      "scheduled" => [ "booked", %w[scheduled] ],
      "completed" => [ "attended", %w[completed] ],
      "denied" => [ "cancelled", %w[denied] ],
      "cancelled" => [ "cancelled", %w[cancelled] ]
    }.freeze

    module_function

    # -> Target(status:, at:) | :none | :excluded
    def for(request, settings:)
      return :none if request.status == "draft"
      return :excluded if request.state_regulated && !settings.send_external

      return Target.new(status: closed_status(request), at: last_at(request, %w[closed])) if request.status == "closed"

      status, events = RULES.fetch(request.status) { raise ArgumentError, "situação sem correspondência: #{request.status}" }
      Target.new(status: status, at: last_at(request, events) || request.requested_at)
    end

    # -> [{ "status" => "absence", "at" => iso8601(6) }]: uma por linha `missed`
    # depois de `since` (nil = todas), menos a última se o pedido está
    # fechado (é a situação desejada), sem repetir o desejado no fim. `settings`
    # e `facts` evitam reler o que o chamador já tem.
    #
    # Q31: a falta intermediária que nunca sai (sem horário nem prestador na
    # linha e sem no_show da cadeia, a `external_absence_without_schedule`) é
    # pulada aqui, calculada a cada chamada, sem marcador gravado. Só a falta
    # antiga que é a situação desejada (o último passo) segue bloqueando, na
    # validação do envio.
    def steps(request, since:, settings: nil, facts: nil)
      settings ||= RegulationRndsSetting.current
      rows = request.events.select { |e| e.status == "missed" && (since.nil? || e.created_at > since) }
      rows = rows.first(rows.size - 1) if request.status == "closed" && rows.any?
      rows = sendable(request, rows, settings, facts)
      # Com os microssegundos (N1): o `at` é a chave da linha `missed` na
      # montagem (RiraBundle.absence_slot); sem eles, a linha ficaria "depois".
      steps = rows.map { |e| { "status" => ABSENCE, "at" => e.created_at.iso8601(6) } }
      steps = steps.chunk_while { |a, b| a["status"] == b["status"] }.map(&:first)
      desired = self.for(request, settings: settings)
      steps.pop if desired.is_a?(Target) && desired.status == steps.last&.fetch("status")
      steps
    end

    # A situação MIRA do `closed` (a regra única, também do RiraFacts): com
    # MAX_MISSES faltas, `absence`; senão `cancelled`.
    def closed_status(request) = request.misses >= CareRegulation::Catalog::MAX_MISSES ? ABSENCE : "cancelled"

    # As faltas com horário resolvível (a mesma regra da validação: o
    # `RiraBundle.absence_slot` do instante da falta).
    def sendable(request, rows, settings, facts)
      return rows if rows.empty?

      facts ||= RiraFacts.for(request: request, settings: settings, credential: nil)
      rows.reject { |e| RiraBundle.absence_slot(facts, e.created_at).nil? }
    end

    def last_at(request, statuses)
      request.events.select { |e| statuses.include?(e.status) }.map(&:created_at).max
    end
    private_class_method :last_at, :sendable
  end
end
