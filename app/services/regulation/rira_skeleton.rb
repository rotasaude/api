module Regulation
  # Esqueleto do documento RIRA (módulo 26c; Valor 4, `skeleton:<caminho>`):
  # os campos de presença obrigatória (mín. 1) dos quatro perfis do pacote
  # oficial 1.0.0 — o spec os confere contra os StructureDefinitions do
  # fixture — e o mínimo do Bundle `document` (bdl-9, bdl-10).
  # `problems(bundle)` devolve os CAMINHOS ausentes, nunca valores (o Bundle é
  # dado sensível); quem chama prefixa `skeleton:`. Numa lista, todo item
  # precisa do campo.
  #
  # Só a cardinalidade: as invariantes condicionais do perfil (mira-2..19:
  # data, executante e data de execução por situação) não são conferidas aqui.
  module RiraSkeleton
    BUNDLE = %w[type timestamp identifier.system identifier.value].freeze
    RESOURCES = %w[Composition Appointment ServiceRequest Condition].freeze
    REQUIRED = {
      "Composition" => %w[
        status type.coding.system type.coding.code category.coding.system category.coding.code subject date
        author.identifier.system author.identifier.value title event.code.coding.system event.code.coding.code
        event.period.end section.entry.reference
      ],
      "Appointment" => %w[
        status serviceCategory.coding.system serviceCategory.coding.code serviceType.coding.system serviceType.coding.code
        appointmentType.coding.system appointmentType.coding.code basedOn.reference participant.type.coding.system
        participant.type.coding.code participant.actor.identifier.system participant.actor.identifier.value participant.status
      ],
      "ServiceRequest" => %w[
        status intent category.coding.system category.coding.code priority code.coding.system code.coding.code
        subject.identifier.system subject.identifier.value authoredOn requester.identifier.system requester.identifier.value
      ],
      "Condition" => %w[code.coding.system code.coding.code subject.identifier.system subject.identifier.value]
    }.transform_values(&:freeze).freeze

    module_function

    # -> [String] (caminhos ausentes; [] = esqueleto completo)
    def problems(bundle)
      return [ "Bundle" ] unless bundle.is_a?(Hash)

      problems = []
      problems << "Bundle.type" unless bundle["type"] == "document"
      problems.concat(missing("Bundle", bundle, BUNDLE - %w[type]))
      entries = Array(bundle["entry"])
      resources = entries.map { |entry| entry.is_a?(Hash) ? entry["resource"] : nil }
      RESOURCES.each_with_index do |type, index|
        resource = resources[index]
        next problems << "Bundle.entry.#{type}" unless resource.is_a?(Hash) && resource["resourceType"] == type

        problems.concat(missing(type, resource, REQUIRED.fetch(type)))
      end
      problems.concat(references(entries, resources)) if problems.none? { |path| path.start_with?("Bundle.entry") }
      problems
    end

    def missing(prefix, node, paths)
      paths.reject { |path| present?(node, path.split(".")) }.map { |path| "#{prefix}.#{path}" }
    end

    # Cada nó do caminho tem o filho (numa lista, todos os itens).
    def present?(node, keys)
      return !blank?(node) if keys.empty?

      nodes = node.is_a?(Array) ? node : [ node ]
      nodes.any? && nodes.all? { |item| item.is_a?(Hash) && !blank?(item[keys.first]) && present?(item[keys.first], keys.drop(1)) }
    end

    # As referências internas apontam a entrada certa.
    def references(entries, resources)
      urls = entries.map { |entry| entry["fullUrl"] }
      expected = { "Composition.section.entry.reference" => [ resources[0].dig("section", 0, "entry", 0, "reference"), urls[1] ],
                   "Appointment.basedOn.reference" => [ resources[1].dig("basedOn", 0, "reference"), urls[2] ] }
      expected.filter_map { |path, (found, url)| path if url.blank? || found != url }
    end

    def blank?(value) = value.nil? || value == "" || (value.respond_to?(:empty?) && value.empty?)
    private_class_method :missing, :present?, :references, :blank?
  end
end
