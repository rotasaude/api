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

      if request.status == "closed"
        absent = request.misses >= CareRegulation::Catalog::MAX_MISSES
        return Target.new(status: absent ? ABSENCE : "cancelled", at: last_at(request, %w[closed]))
      end

      status, events = RULES.fetch(request.status) { raise ArgumentError, "situação sem correspondência: #{request.status}" }
      Target.new(status: status, at: last_at(request, events) || request.requested_at)
    end

    # -> [{ "status" => "absence", "at" => iso8601 }]: uma por linha `missed`
    # depois de `since` (nil = todas), menos a última se o pedido está
    # fechado (é a situação desejada), sem repetir o desejado no fim.
    def steps(request, since:)
      rows = request.events.select { |e| e.status == "missed" && (since.nil? || e.created_at > since) }
      rows = rows.first(rows.size - 1) if request.status == "closed" && rows.any?
      steps = rows.map { |e| { "status" => ABSENCE, "at" => e.created_at.iso8601 } }
      steps = steps.chunk_while { |a, b| a["status"] == b["status"] }.map(&:first)
      desired = self.for(request, settings: RegulationRndsSetting.current)
      steps.pop if desired.is_a?(Target) && desired.status == steps.last&.fetch("status")
      steps
    end

    def last_at(request, statuses)
      request.events.select { |e| statuses.include?(e.status) }.map(&:created_at).max
    end
    private_class_method :last_at
  end
end
