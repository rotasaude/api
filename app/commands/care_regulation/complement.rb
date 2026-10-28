# Complementar um pedido devolvido (ADR 0044; contrato §5, §13 G10, G12, G14;
# plano do api, Desvios 5 e 10): `returned` → `pending`, pela unidade que pediu.
#
# - quem: health_professional com vínculo ativo (ProfessionalLink.active) na
#   unidade solicitante (senão missing_role); "o CBO do vínculo" é o do
#   primeiro vínculo ativo ali, por started_at, cujo CBO passa no
#   Requesters.check do alvo (nenhum passa → cbo_not_allowed);
# - corpo `{ justification, cid10?, ciap2?, suggested_color? }` (+ version):
#   chave ausente mantém o valor atual, chave com null limpa (G10). O par
#   resultante passa por Diagnosis.check com o mesmo CBO e kept_cid10 = o
#   CID-10 que já estava no pedido (G12: não é recusado para o enfermeiro);
# - a justificativa nova substitui a do pedido e vai no `reason` do evento
#   `pending` (o histórico); requested_at e a autoria não mudam;
# - due_on recalculado só se a cor efetiva (color ?? suggested_color, G14)
#   mudar, contando da data original do pedido (Desvio 5).
#
# Justificativa, diagnóstico e cor nunca em log, evento nem Result de recusa.
module CareRegulation
  module Complement
    KEYS = %w[justification cid10 ciap2 suggested_color].freeze
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(request:) | fail(:invalid_request, details: { path: }) |
    # fail(:missing_role | :cbo_not_allowed | :stale_version | :invalid_transition |
    # :invalid_cid10 | :invalid_ciap2 | :diagnosis_required | :cid10_not_allowed_for_cbo)
    def call(request:, attrs:, version:, by:)
      attrs = shape(attrs)
      return attrs if attrs.is_a?(Result)
      return invalid("version") unless version.is_a?(Integer)
      return invalid("justification") unless attrs["justification"].is_a?(String)
      return Result.fail(:missing_role) unless by&.has_role?("health_professional")

      links = ProfessionalLink.active.joins(:professional)
                              .where(professionals: { user_id: by.id }, health_unit_id: request.requester_unit_id)
                              .order(:started_at, :id).to_a
      return Result.fail(:missing_role) if links.empty?

      target = target_of(request)
      cbo = links.map(&:cbo_code).find { |code| Requesters.check(cbo: code, target: target) == :ok }
      return Result.fail(:cbo_not_allowed) unless cbo

      ApplicationRecord.transaction(requires_new: true) do
        request.lock!
        next Result.fail(:stale_version) if version != request.version
        next Result.fail(:invalid_transition) unless request.status == "returned"

        changes = values(request, attrs, cbo)
        next changes if changes.is_a?(Result)

        resulting = request.color || changes.fetch(:suggested_color)
        if resulting != request.effective_color
          changes[:due_on] = Deadlines.due_on(requested_at: request.requested_at, color: resulting)
        end

        transitioned = Transition.call(request: request, to: "pending", by: by, reason: changes.fetch(:justification),
                                       version: version, changes: changes, event: "complemented")
        # A versão já foi conferida sob a trava: só falha por erro de programação.
        raise ArgumentError, "complemento recusado: #{transitioned.reason}" unless transitioned.ok?

        Result.ok(request: request)
      end
    end

    # Só um Hash de chaves conhecidas.
    def shape(attrs)
      return invalid("body") unless attrs.respond_to?(:to_h) && !attrs.is_a?(Array)

      hash = attrs.to_h.stringify_keys
      unknown = (hash.keys - KEYS).first
      unknown ? invalid(unknown.to_s[0, KEY_PATH_MAX]) : hash
    end

    # -> Hash a gravar | Result (recusa). Ausente mantém; null limpa. Quando o
    # cid10 vem ausente, o atual entra como kept (nem revalidado nem recusado);
    # com null não há o que manter.
    def values(request, attrs, cbo)
      cid10 = attrs.fetch("cid10", nil)
      kept = attrs.key?("cid10") && attrs["cid10"].nil? ? nil : request.cid10
      ciap2 = attrs.key?("ciap2") ? attrs["ciap2"] : request.ciap2
      diagnosis = Diagnosis.check(cbo: cbo, cid10: cid10, ciap2: ciap2, kept_cid10: kept)
      return diagnosis if diagnosis.failure?

      text = attrs.fetch("justification").strip
      return invalid("justification") unless Catalog::JUSTIFICATION.cover?(text.length)

      color = attrs.key?("suggested_color") ? attrs["suggested_color"] : request.suggested_color
      return invalid("suggested_color") unless Catalog::COLORS.include?(color)

      { justification: text, cid10: diagnosis.payload[:cid10], ciap2: diagnosis.payload[:ciap2], suggested_color: color }
    end

    # O alvo do pedido para o Requesters.check (tipo, código e grupo), sem
    # revalidar a regulabilidade: o pedido já foi aceito e o alvo nunca muda.
    def target_of(request)
      group = if request.target_type == "procedure" then "procedure"
              elsif request.target_code.start_with?(Catalog::DENTIST_PREFIX) then "dental"
              else "medical"
              end
      Target.new(type: request.target_type, code: request.target_code, name: request.target_name, group: group,
                 label: request.target_name)
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :shape, :values, :target_of, :invalid
  end
end
